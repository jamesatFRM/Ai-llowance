import Foundation
import Darwin

/// Unified subscription credits only. Legacy Build budgets do not establish Bot coverage.
public enum GrokUsageParser {
    public static func identity(_ data: Data) throws -> String {
        struct Info: Decodable { let methodId: String?; let email: String?; let teamId: String?; let principalType: String? }
        guard data.count <= 2_000_000, let info = try? JSONDecoder().decode(Info.self, from: data),
              ["cached_token", "grok.com"].contains(info.methodId ?? ""), info.principalType == "User",
              let email = info.email, email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
              email.utf8.count <= 254, let team = info.teamId, UUID(uuidString: team) != nil else { throw UsageError.authentication }
        // Team binding prevents switching workspaces under the same email from mixing history.
        return "\(email.lowercased()) · \(team.lowercased())"
    }
    public static func parse(_ data: Data, at now: Date, identity: String, expectedIdentity: String? = nil) throws -> Snapshot {
        struct Period: Decodable { let type: String; let start: String; let end: String }
        struct Config: Decodable { let creditUsagePercent: Double?; let currentPeriod: Period?; let isUnifiedBillingUser: Bool? }
        struct Reply: Decodable { let config: Config? }
        guard data.count <= 2_000_000, !identity.isEmpty else { throw UsageError.invalidData }
        if let expectedIdentity, identity.caseInsensitiveCompare(expectedIdentity) != .orderedSame {
            throw UsageError.accountChanged(expectedIdentity)
        }
        do {
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard let config = reply.config, config.isUnifiedBillingUser == true else {
                throw UsageError.unavailable("Grok did not confirm a unified subscription. Legacy Grok Bot allowance is not supported; no usage has been inferred.")
            }
            guard let percent = config.creditUsagePercent, let period = config.currentPeriod else { throw UsageError.invalidData }
            let weekly = period.type == "USAGE_PERIOD_TYPE_WEEKLY"
            guard weekly || period.type == "USAGE_PERIOD_TYPE_MONTHLY" else { throw UsageError.invalidData }
            func date(_ text: String) -> Date? {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let value = f.date(from: text); f.formatOptions = [.withInternetDateTime]
                return value ?? f.date(from: text)
            }
            guard let start = date(period.start), let end = date(period.end), start <= now, end > now,
                  end > start, end.timeIntervalSince(start) <= 32 * 86400 else { throw UsageError.invalidData }
            let window = try QuotaWindow(id: weekly ? "grok.shared.weekly" : "grok.shared.monthly",
                label: weekly ? "Shared weekly allowance" : "Shared monthly allowance", usedPercent: percent,
                resetsAt: end, durationMinutes: weekly ? 10080 : Int(end.timeIntervalSince(start) / 60))
            return try Snapshot(observedAt: now, windows: [window], periodStart: start, identity: identity,
                source: "Grok CLI · unified subscription",
                note: "One shared pool for Grok, Grok Bot, and Cursor. The CLI reports whole percentages; Grok Bot may round differently. API credits are separate.",
                freshnessInterval: 1800).validated()
        } catch let error as UsageError { throw error }
        catch { throw UsageError.invalidData }
    }
}

struct GrokLineDecoder {
    var buffer = Data()
    mutating func append(_ bytes: Data) throws {
        guard buffer.count + bytes.count <= 2_016_384 else { throw UsageError.invalidData }
        buffer.append(bytes)
    }
    mutating func next() throws -> Data? {
        guard let end = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
        guard !line.isEmpty, line.count <= 2_000_000 else { throw UsageError.invalidData }
        return line
    }
}

private final class GrokRPC {
    private let process = Process(); private let input = Pipe(); private let output = Pipe()
    private var decoder = GrokLineDecoder(); private var sequence = 0; private var stopped = false
    private let deadline: Date
    private var totalBytes = 0
    init(executable: URL, directory: URL, timeout: TimeInterval) throws {
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = executable
        process.arguments = ["agent", "--no-leader", "stdio"]
        // Never inherit an API token that silently changes which account is measured.
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "NO_COLOR": "1"]
        process.currentDirectoryURL = directory
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try CommandOutput.protectInput(input)
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
        var data = payload; data.append(0x0A)
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
            guard count > 0 else { throw UsageError.unavailable("Grok closed its quota connection. Check sign-in and CLI compatibility.") }
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
                    if error["code"] as? Int == -32000 { throw UsageError.authentication }
                    throw UsageError.unavailable("Grok could not read account quota. Check CLI sign-in, version, and organization access.")
                }
                guard let result = value["result"] as? [String: Any] else { throw UsageError.invalidData }
                return result
            }
            // No reverse RPC (tools, login UI, or approval) is authorized by a quota read.
            if value["id"] != nil, value["method"] != nil {
                // Never echo an arbitrary-size server ID into a blocking pipe write.
                // Closing this quota-only connection also prevents interactive work.
                throw UsageError.unavailable("Grok requested an unsupported interactive action while reading quota.")
            }
        }
        throw UsageError.invalidData
    }
    func initialize() throws {
        let reply = try call("initialize", params: ["protocolVersion": 1, "clientCapabilities": [:],
            "clientInfo": ["name": "ai-llowance", "version": "1"]])
        guard reply["protocolVersion"] as? Int == 1 else {
            throw UsageError.unavailable("This Grok CLI protocol is not supported. Update Ai-llowance and Grok CLI.")
        }
    }
    func identity() throws -> String {
        try GrokUsageParser.identity(JSONSerialization.data(withJSONObject: call("_x.ai/auth/info")))
    }
}

public struct GrokAdapter: UsageAdapter {
    public let executable: URL
    public let timeout: TimeInterval
    public init(executable: URL, timeout: TimeInterval = 35) { self.executable = executable; self.timeout = timeout }
    public static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.grok/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    public func fetch(account: Account, now: Date) async throws -> Snapshot {
        guard account.kind == .grokSubscription else { throw UsageError.invalidData }
        guard account.scopeID?.isEmpty != false else {
            throw UsageError.unavailable("Selected Grok profiles are not supported yet. Use the existing CLI sign-in.")
        }
        let worker = Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-llowance-quota-\(UUID().uuidString)")
            try Paths.prepare(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let rpc = try GrokRPC(executable: executable, directory: directory, timeout: timeout)
            defer { rpc.stop() }
            try rpc.initialize()
            let before = try rpc.identity()
            if let expected = account.expectedIdentity, before.caseInsensitiveCompare(expected) != .orderedSame {
                throw UsageError.accountChanged(expected)
            }
            let data = try JSONSerialization.data(withJSONObject: rpc.call("_x.ai/billing"))
            guard try rpc.identity() == before else { throw UsageError.accountChanged(account.expectedIdentity ?? before) }
            return try GrokUsageParser.parse(data, at: now, identity: before, expectedIdentity: account.expectedIdentity)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
