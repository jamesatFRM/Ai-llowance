import Foundation
import Darwin

// A short-lived, stdio-only child. No shell, inference, conversation reads, or token-file parsing.
// All blocking pipe work is performed in a detached task, never on the UI executor.
final class CodexRPC {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var buffer = Data()
    var sequence = 0
    var stopped = false
    var queuedNotifications: [[String: Any]] = []
    let deadline: Date
    init(executable: URL, home: URL, existing: Bool, timeout: TimeInterval) throws {
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        if !existing { process.arguments! += ["-c", "cli_auth_credentials_store=\"keyring\""] }
        // Start with a small environment: inherited API keys must not select the wrong billing identity.
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "CODEX_HOME": home.path,
            "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = home
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    deinit { stop() }
    func stop() {
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        try? output.fileHandleForReading.close()
    }
    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func next() throws -> [String: Any] {
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw UsageError.timeout }
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                if line.isEmpty { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw UsageError.invalidData }
                return object
            }
            guard buffer.count < 2_000_000 else { throw UsageError.invalidData }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 250)
            if result < 0 { if errno == EINTR { continue }; throw UsageError.server }
            if result == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageError.unavailable("Codex app-server closed the connection. Update Codex CLI and try again.") }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
    func call(_ method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        sequence += 1
        var request: [String: Any] = ["id": sequence, "method": method]
        if let params { request["params"] = params }
        try send(request)
        while true {
            let message = try next()
            if let id = message["id"] as? Int, id == sequence, message["method"] == nil {
                if message["error"] != nil {
                    // Raw provider errors can contain credentials or other private data.
                    throw UsageError.unavailable("Codex could not complete \(method). Check sign-in and CLI compatibility.")
                }
                guard let result = message["result"] as? [String: Any] else { throw UsageError.invalidData }
                return result
            }
            if message["method"] as? String == "account/login/completed" { queuedNotifications.append(message) }
        }
    }
    func initialize() throws {
        _ = try call("initialize", params: ["clientInfo": ["name": "usagebar", "version": "0.1.0"]])
        try send(["method": "initialized"])
    }
}

public struct CodexAdapter: UsageAdapter {
    public let executable: URL
    public let root: URL
    public init(executable: URL, root: URL = Paths.root) { self.executable = executable; self.root = root }
    public static func findExecutable() -> URL? {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    public func home(_ account: Account) -> URL {
        account.usesExistingCodex ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") : Paths.profile(account.id, root: root)
    }
    public func fetch(account: Account, now: Date) async throws -> Snapshot {
        let home = home(account)
        let worker = Task.detached(priority: .utility) {
            let rpc = try CodexRPC(executable: executable, home: home, existing: account.usesExistingCodex, timeout: 25)
            defer { rpc.stop() }
            try rpc.initialize()
            let info = try rpc.call("account/read", params: ["refreshToken": true])
            guard let identity = info["account"] as? [String: Any] else { throw UsageError.authentication }
            guard identity["type"] as? String == "chatgpt" else {
                throw UsageError.unavailable("This Codex profile uses API billing. Connect an OpenAI API spending account instead, or sign in with ChatGPT.")
            }
            let response = try rpc.call("account/rateLimits/read")
            let data = try JSONSerialization.data(withJSONObject: response)
            return try UsageParser.codex(data, at: now, identity: identity["email"] as? String)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    public func login(account: Account, openURL: @escaping @Sendable (URL) -> Void) async throws {
        guard !account.usesExistingCodex else { throw UsageError.unavailable("Manage sign-in for the existing profile in Codex CLI.") }
        let home = home(account)
        try Paths.prepare(home)
        let worker = Task.detached(priority: .utility) {
            let rpc = try CodexRPC(executable: executable, home: home, existing: false, timeout: 180)
            defer { rpc.stop() }
            try rpc.initialize()
            let result = try rpc.call("account/login/start", params: ["type": "chatgpt"])
            guard let link = result["authUrl"] as? String, let url = URL(string: link), url.scheme == "https",
                  let host = url.host, ["auth.openai.com", "auth0.openai.com", "chatgpt.com"].contains(host),
                  let loginID = result["loginId"] as? String else { throw UsageError.invalidData }
            openURL(url)
            while true {
                let message = try rpc.queuedNotifications.isEmpty ? rpc.next() : rpc.queuedNotifications.removeFirst()
                if message["method"] as? String == "account/login/completed",
                   let params = message["params"] as? [String: Any], params["loginId"] as? String == loginID {
                    guard params["success"] as? Bool == true else { throw UsageError.authentication }
                    return
                }
            }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    public func logout(account: Account) async throws {
        guard !account.usesExistingCodex else { return } // Never log the user's other tools out.
        let home = home(account)
        let worker = Task.detached(priority: .utility) {
            let rpc = try CodexRPC(executable: executable, home: home, existing: false, timeout: 20)
            defer { rpc.stop() }
            try rpc.initialize()
            _ = try rpc.call("account/logout")
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
