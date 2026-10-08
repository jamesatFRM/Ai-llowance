import Foundation

public protocol UsageAdapter: Sendable {
    func fetch(account: Account, now: Date) async throws -> Snapshot
}
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public final class SecureHTTPTransport: HTTPTransport, Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidData }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw UsageError.invalidData }
            data.append(byte)
        }
        return (data, http)
    }
}

public struct CostAdapter: UsageAdapter {
    private let transport: any HTTPTransport
    private let credential: @Sendable (UUID) throws -> String
    public init(transport: any HTTPTransport = SecureHTTPTransport(), credential: @escaping @Sendable (UUID) throws -> String = { try KeychainStore().read($0) }) {
        self.transport = transport; self.credential = credential
    }
    public static func monthStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .month, for: date)!.start
    }
    public static func request(kind: ConnectionKind, key: String, now: Date, page: String?) throws -> URLRequest {
        guard kind.isAPI, !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw UsageError.missingCredential }
        let start = monthStart(now)
        var components = URLComponents(string: kind == .openAIAPI ? "https://api.openai.com/v1/organization/costs" : "https://api.anthropic.com/v1/organizations/cost_report")!
        if kind == .openAIAPI {
            components.queryItems = [URLQueryItem(name: "start_time", value: "\(Int(start.timeIntervalSince1970))"),
                URLQueryItem(name: "end_time", value: "\(Int(now.timeIntervalSince1970))"),
                URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "31")]
        } else {
            let format = ISO8601DateFormatter()
            components.queryItems = [URLQueryItem(name: "starting_at", value: format.string(from: start)),
                URLQueryItem(name: "ending_at", value: format.string(from: now)),
                URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "31")]
        }
        if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if kind == .openAIAPI { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        else {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }
    public func fetch(account: Account, now: Date) async throws -> Snapshot {
        let key = try credential(account.id)
        var page: String?; var seen: Set<String> = []; var total: Decimal = 0
        for _ in 0..<20 {
            try Task.checkCancellation()
            let request = try Self.request(kind: account.kind, key: key, now: now, page: page)
            let (data, response) = try await transport.data(for: request)
            switch response.statusCode {
            case 200: break
            case 401: throw UsageError.authentication
            case 403: throw UsageError.forbidden
            case 429: throw UsageError.rateLimited(Self.retryDelay(response, now: now))
            case 500...599: throw UsageError.server
            default: throw UsageError.invalidData
            }
            let result = try UsageParser.costs(data, kind: account.kind)
            total += result.amount
            guard !total.isNaN else { throw UsageError.invalidData }
            guard let next = result.nextPage else {
                return Snapshot(observedAt: now, costUSD: total, periodStart: Self.monthStart(now),
                    source: "Organization cost report · UTC month to date",
                    note: account.kind == .claudeAPI ? "Reporting may lag. Priority Tier costs are excluded. Not a subscription limit or final invoice." : "Reporting may lag. Not a subscription limit, credit balance, or final invoice.")
            }
            guard seen.insert(next).inserted else { throw UsageError.invalidData }
            page = next
        }
        // Never present a truncated sum as a complete monthly total.
        throw UsageError.invalidData
    }
    public static func retryDelay(_ response: HTTPURLResponse, now: Date) -> TimeInterval {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return 300 }
        if let seconds = Double(header), seconds.isFinite { return max(0, seconds) }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return max(0, format.date(from: header)?.timeIntervalSince(now) ?? 300)
    }
}

public struct ClaudeAdapter: UsageAdapter {
    let root: URL
    public init(root: URL = Paths.root) { self.root = root }
    public func fetch(account: Account, now: Date) async throws -> Snapshot {
        try ClaudeFeed.read(Paths.feed(account.id, root: root), accountID: account.id)
    }
}
