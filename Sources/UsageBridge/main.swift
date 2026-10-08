import Foundation
import UsageCore

@main
struct UsageBridge {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--probe-codex", args.count == 2 {
                // Explicitly supplied executable; uses the CLI's existing sign-in without reading tokens.
                let adapter = CodexAdapter(executable: URL(fileURLWithPath: args[1]))
                let account = Account(name: "Existing CLI", kind: .codex, usesExistingCodex: true)
                let snapshot = try await adapter.fetch(account: account, now: Date())
                // Do not print identity or quota amounts in diagnostic logs.
                print("Codex connection succeeded: \(snapshot.windows.count) quota windows; identity \(snapshot.identity == nil ? "unavailable" : "present").")
                return
            }
            if args.first == "--probe-claude", args.count == 2 {
                let account = Account(name: "Existing CLI", kind: .claudeCode, usesExistingClaude: true)
                let snapshot = try await ClaudeUsageAdapter(executable: URL(fileURLWithPath: args[1])).fetch(account: account, now: Date())
                print("Claude direct usage succeeded: \(snapshot.windows.count) windows.")
                for window in snapshot.windows { print("\(window.label): \(window.usedPercent)% used; reset \(window.resetsAt == nil ? "not parsed" : "present")") }
                return
            }
            guard args.count == 2, args[0] == "--account", let id = UUID(uuidString: args[1]) else {
                throw UsageError.unavailable("Usage: UsageBridge --account ACCOUNT_UUID < Claude status-line JSON")
            }
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
                guard data.count + chunk.count <= 1_048_576 else { throw UsageError.invalidData }
                data.append(chunk)
            }
            let snapshot = try UsageParser.claude(data)
            // Only quota fields and observation time survive. No session text, paths, or tokens.
            try Paths.write(ClaudeFeed(accountID: id, snapshot: snapshot), to: Paths.feed(id))
            let label = snapshot.windows.map { "\($0.label): \(Int($0.remainingPercent))% left" }.joined(separator: " · ")
            print(label.isEmpty ? "UsageBar: quota unavailable" : label)
        } catch {
            // Fixed safe errors only; never echo the stdin payload or provider response.
            let message = (error as? UsageError)?.localizedDescription ?? "UsageBar could not read usage data."
            try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
            exit(1)
        }
    }
}
