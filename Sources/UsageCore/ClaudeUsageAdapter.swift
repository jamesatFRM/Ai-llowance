import Foundation
import Darwin

/// Uses the installed Claude CLI's built-in local /usage command. No OAuth extraction or private HTTP API.
public struct ClaudeUsageAdapter: UsageAdapter, Sendable {
    public let executable: URL
    public let root: URL
    public init(executable: URL, root: URL = Paths.root) { self.executable = executable; self.root = root }

    public func fetch(account: Account, now: Date) async throws -> Snapshot {
        let connection = ClaudeConnection(root: root, executable: executable, bundledBridge: executable)
        let identity = try await connection.authIdentity(account: account)
        guard identity.signedIn else { throw UsageError.authentication }
        let profile = connection.config(account)
        let work = root.appendingPathComponent("ClaudeConnections/\(account.id.uuidString)/UsageCheck")
        try Paths.prepare(work)
        let executable = self.executable
        let worker = Task.detached(priority: .utility) {
            let process = Process(); let output = Pipe()
            process.executableURL = executable
            process.arguments = ["-p", "/usage", "--output-format", "json", "--safe-mode", "--no-session-persistence",
                                 "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "USER": NSUserName(), "LOGNAME": NSUserName(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "LANG": "en_US.UTF-8", "CLAUDE_CONFIG_DIR": profile.path, "NO_COLOR": "1",
                "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1"]
            process.currentDirectoryURL = work
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let result = try CommandOutput.read(process, output: output, timeout: 25, limit: 1_048_576)
            guard result.exitCode == 0 else { throw UsageError.unavailable("Claude could not finish its usage check. Try refreshing; if this continues, sign in again.") }
            var snapshot = try ClaudeUsageReport.parse(result.data, at: Date())
            snapshot.identity = identity.email
            return snapshot
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

/// The CLI JSON envelope is structured; plan rows inside `result` are text and version-dependent.
/// Accept only explicit percentages from known plan rows. Never parse attribution percentages as quota.
public enum ClaudeUsageReport {
    public static func parse(_ data: Data, at now: Date) throws -> Snapshot {
        struct Report: Decodable {
            let type: String; let subtype: String; let is_error: Bool
            let result: String?; let num_turns: Int?; let total_cost_usd: Decimal?
        }
        let report = try JSONDecoder().decode(Report.self, from: data)
        guard report.type == "result", report.subtype == "success", !report.is_error,
              report.num_turns == 0, report.total_cost_usd == 0, let text = report.result else {
            throw UsageError.unavailable("Claude’s usage command did not return a supported read-only report. Update Claude Code and try again.")
        }
        let lower = text.lowercased()
        if lower.contains("last-known") || lower.contains("last known") || lower.contains("rate limited") || lower.contains("rate-limited") || lower.contains("cached usage") {
            throw UsageError.rateLimited(300)
        }
        let regex = try NSRegularExpression(pattern: #"^(Current session|Current week \(([^)]+)\)): ([0-9]+(?:\.[0-9]+)?)% used(?: · resets (.+))?$"#)
        var windows: [QuotaWindow] = []
        var ids = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            // Only the plan summary preceding the local behavioral analysis is authoritative here.
            if line.hasPrefix("What's contributing") { break }
            guard line.hasPrefix("Current session:") || line.hasPrefix("Current week") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { throw UsageError.invalidData }
            func group(_ index: Int) -> String? {
                guard let range = Range(match.range(at: index), in: line) else { return nil }
                return String(line[range])
            }
            guard let percentText = group(3), let percent = Double(percentText) else { throw UsageError.invalidData }
            let model = group(2)
            let id = model.map { "week.\($0)" } ?? "session"
            guard ids.insert(id).inserted else { throw UsageError.invalidData }
            let label = model.map { $0 == "all models" ? "Week · 7d" : "\($0) · 7d" } ?? "Session · 5h"
            windows.append(try QuotaWindow(id: id, label: label, usedPercent: percent,
                                          resetsAt: group(4).flatMap { resetDate($0, now: now) }, durationMinutes: model == nil ? 300 : 10_080))
        }
        guard !windows.isEmpty, ids.contains("session"), ids.contains("week.all models") else {
            throw UsageError.unavailable("Claude Code did not return plan limits. Update Claude Code to a version that supports /usage in print mode, then refresh.")
        }
        return Snapshot(observedAt: now, windows: windows, source: "Claude Code /usage",
                        note: "Read directly from Claude’s plan-usage command. No conversation or open Terminal is needed for updates.")
    }

    static func resetDate(_ value: String, now: Date) -> Date? {
        guard let start = value.lastIndex(of: "("), value.hasSuffix(")"),
              let zone = TimeZone(identifier: String(value[value.index(after: start)..<value.index(before: value.endIndex)])) else { return nil }
        let raw = String(value[..<start]).trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let year = calendar.component(.year, from: now)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone; formatter.isLenient = false
        for candidateYear in [year, year + 1] {
            for format in ["yyyy MMM d 'at' h:mma", "yyyy MMM d 'at' ha"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: "\(candidateYear) \(raw)"), date > now.addingTimeInterval(-60), date < now.addingTimeInterval(8 * 86400) { return date }
            }
        }
        return nil
    }
}
