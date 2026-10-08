import Foundation
import Darwin

public enum ShellQuote {
    public static func argument(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public struct ClaudeConnection: Sendable {
    public let root: URL
    public let executable: URL
    public let bundledBridge: URL
    public let existingConfig: URL
    public init(root: URL = Paths.root, executable: URL, bundledBridge: URL,
                existingConfig: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.root = root; self.executable = executable; self.bundledBridge = bundledBridge; self.existingConfig = existingConfig
    }
    public static func findExecutable() -> URL? {
        let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    public func config(_ account: Account) -> URL {
        account.usesExistingClaude == true ? existingConfig : Paths.claudeProfile(account.id, root: root)
    }
    private func folder(_ account: Account) -> URL { root.appendingPathComponent("ClaudeConnections/\(account.id.uuidString)") }
    private struct Record: Codable {
        let accountID: UUID
        let settingsPath: String
        let installedCommand: String
        let previousStatusLine: Data?
    }
    private func writePrivate(_ data: Data, to url: URL, executable: Bool = false) throws {
        try Paths.prepare(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
    }
    private func readSettings(_ url: URL) throws -> (Data?, [String: Any]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, [:]) }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.unavailable("Claude’s settings could not be read safely. They were left unchanged.")
        }
        return (data, object)
    }
    /// Adds a feed to the selected profile. Existing settings and custom status-line output survive.
    /// The rollback record is saved before changing Claude's settings.
    @discardableResult
    public func install(account: Account) throws -> URL {
        let directory = folder(account)
        let bridge = root.appendingPathComponent("Tools/UsageBridge")
        let binary = try Data(contentsOf: bundledBridge)
        if (try? Data(contentsOf: bridge)) != binary { try writePrivate(binary, to: bridge, executable: true) }
        let settingsURL = config(account).appendingPathComponent("settings.json")
        let recordURL = directory.appendingPathComponent("setup.json")
        let (originalData, originalSettings) = try readSettings(settingsURL)
        var settings = originalSettings
        let record: Record
        if FileManager.default.fileExists(atPath: recordURL.path) {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
            guard record.accountID == account.id, record.settingsPath == settingsURL.path,
                  (settings["statusLine"] as? [String: Any])?["command"] as? String == record.installedCommand else {
                throw UsageError.unavailable("Claude’s status line changed after connection. Remove this connection before setting it up again; your new setting will be preserved.")
            }
        } else {
            let bridgeCommand = "\(ShellQuote.argument(bridge.path)) --account \(account.id.uuidString)"
            var command = bridgeCommand
            let previous = settings["statusLine"].map { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) } ?? nil
            if let existing = settings["statusLine"] as? [String: Any], let oldCommand = existing["command"] as? String, !oldCommand.isEmpty {
                let wrapper = directory.appendingPathComponent("statusline.sh")
                // The original command was already selected by the user. Preserve its stdin and stdout.
                // Payload stays in shell memory; no session content is written to temporary files.
                let script = """
                #!/bin/sh
                usagebar_input="$(cat)"
                printf '%s' "$usagebar_input" | \(bridgeCommand) >/dev/null 2>/dev/null
                printf '%s' "$usagebar_input" | /bin/sh -c \(ShellQuote.argument(oldCommand))
                """
                try writePrivate(Data((script + "\n").utf8), to: wrapper, executable: true)
                command = ShellQuote.argument(wrapper.path)
            } else if settings["statusLine"] != nil {
                throw UsageError.unavailable("This Claude profile has a status-line format UsageBar cannot preserve. Its settings were left unchanged.")
            }
            record = Record(accountID: account.id, settingsPath: settingsURL.path, installedCommand: command, previousStatusLine: previous)
            try Paths.write(record, to: recordURL)
            var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
            statusLine["type"] = "command"; statusLine["command"] = command
            settings["statusLine"] = statusLine
            // Preserve independent edits if the file changed while setup was being prepared.
            let currentData = try? Data(contentsOf: settingsURL)
            guard currentData == originalData else {
                try? FileManager.default.removeItem(at: recordURL)
                throw UsageError.unavailable("Claude’s settings changed during setup. Please connect again.")
            }
            do { try writePrivate(try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: settingsURL) }
            catch { try? FileManager.default.removeItem(at: recordURL); throw error }
        }
        return try launcher(account: account, login: false)
    }
    /// Restore only the field we installed; never overwrite a user's subsequent custom status line.
    public func uninstall(account: Account) throws {
        let recordURL = folder(account).appendingPathComponent("setup.json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
        let url = config(account).appendingPathComponent("settings.json")
        guard record.accountID == account.id, record.settingsPath == url.path else { throw UsageError.invalidData }
        let (original, current) = try readSettings(url)
        var settings = current
        if (settings["statusLine"] as? [String: Any])?["command"] as? String == record.installedCommand {
            if let previous = record.previousStatusLine { settings["statusLine"] = try JSONSerialization.jsonObject(with: previous, options: [.fragmentsAllowed]) }
            else { settings.removeValue(forKey: "statusLine") }
            guard (try? Data(contentsOf: url)) == original else { throw UsageError.unavailable("Claude’s settings changed. Please try removing the connection again.") }
            try writePrivate(try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: url)
        }
        try FileManager.default.removeItem(at: recordURL)
    }
    public func launcher(account: Account, login: Bool, project: URL? = nil, logout: Bool = false, loginOnly: Bool = false) throws -> URL {
        let url = folder(account).appendingPathComponent(logout ? "Sign Out.command" : (login ? "Connect Claude.command" : "Open Claude.command"))
        let work = project ?? folder(account).appendingPathComponent("Workspace")
        try Paths.prepare(work)
        let cli = ShellQuote.argument(executable.path)
        let profile = config(account)
        var script = """
        #!/bin/zsh -f
        set -eu
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL
        unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_PROFILE
        export CLAUDE_CONFIG_DIR=\(ShellQuote.argument(profile.path))
        cd \(ShellQuote.argument(work.path))
        """
        if logout { script += "\n\(cli) auth logout\n" }
        else {
            if login { script += "\n\(cli) auth login --claudeai\n" }
            if account.usesExistingClaude != true {
                script += """

                if [ -f \(ShellQuote.argument(profile.appendingPathComponent(".credentials.json").path)) ]; then
                  \(cli) auth logout >/dev/null 2>&1 || true
                  /bin/rm -f \(ShellQuote.argument(profile.appendingPathComponent(".credentials.json").path))
                  printf '%s\\n' 'Claude could not store this new sign-in in Keychain. Unlock your login Keychain, then click Sign in again in UsageBar.'
                  read -r 'usagebar_done?Press Return to close.'
                  exit 1
                fi
                """
            }
            if loginOnly {
                script += "\nprintf '%s\\n' 'Sign-in complete. You can close this Terminal window. UsageBar will now read your limits automatically.'\n"
            } else {
                script += "\nexec \(cli)\n"
            }
        }
        try writePrivate(Data(script.utf8), to: url, executable: true)
        return url
    }
    public func authStatus(account: Account) async throws -> Bool {
        try await authIdentity(account: account).signedIn
    }
    public func authIdentity(account: Account) async throws -> ClaudeAuthIdentity {
        let cli = executable; let profile = config(account)
        let worker = Task.detached(priority: .utility) {
            let process = Process(); let output = Pipe()
            process.executableURL = cli; process.arguments = ["auth", "status", "--json"]
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "CLAUDE_CONFIG_DIR": profile.path,
                // Claude uses USER to select the macOS Keychain account. Omitting it produces
                // a false logged-out result even when the profile has a valid sign-in.
                "USER": NSUserName(), "LOGNAME": NSUserName()]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.currentDirectoryURL = profile
            try Paths.prepare(profile)
            try process.run()
            defer { if process.isRunning { process.terminate() }; try? output.fileHandleForReading.close() }
            let deadline = Date().addingTimeInterval(10)
            var data = Data()
            while true {
                try Task.checkCancellation()
                guard Date() < deadline else { kill(process.processIdentifier, SIGKILL); throw UsageError.timeout }
                var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                if poll(&fd, 1, 200) <= 0 { continue }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(fd.fd, &chunk, chunk.count)
                if count <= 0 { break }
                guard data.count + count <= 65_536 else { throw UsageError.invalidData }
                data.append(contentsOf: chunk.prefix(count))
            }
            return try ClaudeAuthIdentity.parse(data)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

/// Account metadata from the same isolated CLI profile used to read usage.
public struct ClaudeAuthIdentity: Sendable {
    public let signedIn: Bool
    public let email: String?

    public static func parse(_ data: Data) throws -> Self {
        struct Status: Decodable { let loggedIn: Bool; let authMethod: String; let email: String? }
        let status = try JSONDecoder().decode(Status.self, from: data)
        let signedIn = status.loggedIn && status.authMethod == "claude.ai"
        let email = status.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(signedIn: signedIn, email: signedIn && email?.isEmpty == false ? email : nil)
    }
}
