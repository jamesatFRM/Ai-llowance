import Foundation
import Darwin

public enum CopilotUsageParser {
    private struct Reply: Decodable { let quotaSnapshots: [String: Quota] }
    private struct Quota: Decodable {
        let isUnlimitedEntitlement: Bool
        let entitlementRequests: Double
        let usedRequests: Double
        let remainingPercentage: Double
        let resetDate: String?
        let usageAllowedWithExhaustedQuota: Bool?
        let overageAllowedWithExhaustedQuota: Bool?
    }
    public static func identity(_ data: Data) throws -> String {
        struct Status: Decodable { let isAuthenticated: Bool; let authType: String?; let host: String?; let login: String? }
        guard let value = try? JSONDecoder().decode(Status.self, from: data), value.isAuthenticated,
              ["user", "gh-cli"].contains(value.authType ?? ""), let login = value.login,
              login.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,99}\z"#, options: .regularExpression) != nil,
              let address = value.host, let url = URL(string: address), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.port == nil,
              host == "github.com" || host.hasSuffix(".ghe.com") else { throw UsageError.authentication }
        return host == "github.com" ? login.lowercased() : "\(host.lowercased())/\(login.lowercased())"
    }
    public static func parse(_ data: Data, at now: Date, identity: String, expectedIdentity: String? = nil) throws -> Snapshot {
        guard data.count <= 2_000_000, !identity.isEmpty else { throw UsageError.invalidData }
        if let expectedIdentity, identity.caseInsensitiveCompare(expectedIdentity) != .orderedSame {
            throw UsageError.accountChanged(expectedIdentity)
        }
        do {
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard !reply.quotaSnapshots.isEmpty, reply.quotaSnapshots.count <= 32 else {
                throw UsageError.unavailable("Copilot did not report an account allowance. No remaining quota has been inferred.")
            }
            var windows: [QuotaWindow] = []; var hasUnlimited = false; var paidOverage = false
            for (id, quota) in reply.quotaSnapshots.sorted(by: { $0.key < $1.key }) {
                guard quota.entitlementRequests.isFinite, quota.usedRequests.isFinite, quota.usedRequests >= 0,
                      quota.remainingPercentage.isFinite else { throw UsageError.invalidData }
                if quota.isUnlimitedEntitlement {
                    guard quota.entitlementRequests == -1 else { throw UsageError.invalidData }
                    hasUnlimited = true; continue
                }
                guard quota.entitlementRequests >= 0, (0...100).contains(quota.remainingPercentage) else { throw UsageError.invalidData }
                let reset: Date?
                if let text = quota.resetDate {
                    let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let first = format.date(from: text); format.formatOptions = [.withInternetDateTime]
                    guard let date = first ?? format.date(from: text) else { throw UsageError.invalidData }
                    reset = date
                } else { reset = nil }
                let label = ["premium_interactions": "Premium interactions", "chat": "Chat", "completions": "Completions", "ai_credits": "AI credits"][id] ?? "Copilot quota"
                windows.append(try QuotaWindow(id: id, label: label, usedPercent: 100 - quota.remainingPercentage, resetsAt: reset))
                if quota.overageAllowedWithExhaustedQuota == true || quota.usageAllowedWithExhaustedQuota == true { paidOverage = true }
            }
            return Snapshot(observedAt: now, windows: windows, identity: identity,
                source: "Copilot account quota",
                note: paidOverage ? "Copilot permits additional usage after an allowance is exhausted; additional charges or policies may apply." : "Provider-reported account allowances. Organization policies and other limits may also apply.",
                unlimited: windows.isEmpty && hasUnlimited ? true : nil, freshnessInterval: 1800)
        } catch let error as UsageError { throw error }
        catch { throw UsageError.invalidData }
    }
}

/// vscode-jsonrpc's stdio framing, used by the official Copilot SDK. Not newline JSON.
struct CopilotFrameDecoder {
    var buffer = Data()
    mutating func append(_ bytes: Data) throws {
        guard buffer.count + bytes.count <= 2_016_384 else { throw UsageError.invalidData }
        buffer.append(bytes)
    }
    mutating func next() throws -> Data? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= 16_384 else { throw UsageError.invalidData }; return nil
        }
        guard separator.lowerBound <= 16_384,
              let header = String(data: buffer[..<separator.lowerBound], encoding: .ascii) else { throw UsageError.invalidData }
        let lengths = header.components(separatedBy: "\r\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard lengths.count == 1, let length = Int(lengths[0]), (1...2_000_000).contains(length) else { throw UsageError.invalidData }
        let end = separator.upperBound + length
        guard buffer.count >= end else { return nil }
        let payload = Data(buffer[separator.upperBound..<end]); buffer.removeSubrange(..<end)
        return payload
    }
}

private enum CopilotRPCError: Error { case methodMissing }
private final class CopilotRPC {
    private let process = Process(); private let input = Pipe(); private let output = Pipe()
    private var decoder = CopilotFrameDecoder(); private var sequence = 0; private var stopped = false
    private let deadline: Date
    private var totalBytes = 0
    init(executable: URL, directory: URL, timeout: TimeInterval) throws {
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = executable
        process.arguments = ["--headless", "--no-auto-update", "--stdio", "--log-level", "none"]
        // Never inherit an API token that silently changes which account is measured.
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "NO_COLOR": "1"]
        process.currentDirectoryURL = directory
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    deinit { stop() }
    func stop() {
        guard !stopped else { return }; stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let limit = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? output.fileHandleForReading.close()
    }
    private func send(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var data = Data("Content-Length: \(payload.count)\r\n\r\n".utf8); data.append(payload)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    private func next() throws -> [String: Any] {
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw UsageError.timeout }
            if let data = try decoder.next() {
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["jsonrpc"] as? String == "2.0" else { throw UsageError.invalidData }
                return value
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let polled = poll(&descriptor, 1, 200)
            if polled < 0 { if errno == EINTR { continue }; throw UsageError.server }
            if polled == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageError.unavailable("Copilot closed its quota connection. Check sign-in and CLI compatibility.") }
            totalBytes += count; guard totalBytes <= 4_000_000 else { throw UsageError.invalidData }
            try decoder.append(Data(bytes.prefix(count)))
        }
    }
    func call(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        sequence += 1
        try send(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params])
        for _ in 0..<128 {
            let value = try next()
            if let id = value["id"] as? Int, id == sequence, value["method"] == nil {
                if let error = value["error"] as? [String: Any] {
                    if error["code"] as? Int == -32601 { throw CopilotRPCError.methodMissing }
                    throw UsageError.unavailable("Copilot could not read account quota. Check CLI sign-in, version, and organization access.")
                }
                guard let result = value["result"] as? [String: Any] else { throw UsageError.invalidData }
                return result
            }
            // No reverse RPC (tools, login UI, or approval) is authorized by a quota read.
            if value["id"] != nil, value["method"] != nil {
                // Never echo an arbitrary-size server ID into a blocking pipe write.
                // Closing this quota-only connection also prevents interactive work.
                throw UsageError.unavailable("Copilot requested an unsupported interactive action while reading quota.")
            }
        }
        throw UsageError.invalidData
    }
    func initialize() throws {
        let reply: [String: Any]
        do { reply = try call("connect", params: ["enableGitHubTelemetryForwarding": false]) }
        catch CopilotRPCError.methodMissing { reply = try call("ping") }
        // Official SDK min/max protocol version was 3 when this adapter was verified.
        guard reply["protocolVersion"] as? Int == 3 else {
            throw UsageError.unavailable("This Copilot CLI protocol is not supported. Update Ai-llowance and Copilot CLI.")
        }
    }
    func identity() throws -> String {
        try CopilotUsageParser.identity(JSONSerialization.data(withJSONObject: call("auth.getStatus")))
    }
}

public struct CopilotAdapter: UsageAdapter {
    public let executable: URL
    public let timeout: TimeInterval
    public init(executable: URL, timeout: TimeInterval = 20) { self.executable = executable; self.timeout = timeout }
    public static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot", "\(home)/.local/bin/copilot"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    public func fetch(account: Account, now: Date) async throws -> Snapshot {
        guard account.kind == .copilot else { throw UsageError.invalidData }
        guard account.scopeID?.isEmpty != false else {
            throw UsageError.unavailable("Selected Copilot profiles are not supported yet. Use the existing CLI sign-in.")
        }
        let worker = Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-llowance-quota-\(UUID().uuidString)")
            try Paths.prepare(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let rpc = try CopilotRPC(executable: executable, directory: directory, timeout: timeout)
            defer { rpc.stop() }
            try rpc.initialize()
            let before = try rpc.identity()
            if let expected = account.expectedIdentity, before.caseInsensitiveCompare(expected) != .orderedSame {
                throw UsageError.accountChanged(expected)
            }
            let data = try JSONSerialization.data(withJSONObject: rpc.call("account.getQuota"))
            guard try rpc.identity() == before else { throw UsageError.accountChanged(account.expectedIdentity ?? before) }
            return try CopilotUsageParser.parse(data, at: now, identity: before, expectedIdentity: account.expectedIdentity)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
