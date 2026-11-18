import Foundation
import Darwin

/// Uses the installed Claude CLI's built-in local /usage command. No OAuth extraction or private HTTP API.
public struct ClaudeUsageAdapter: UsageAdapter, Sendable {
    public let executable: URL
    public let root: URL
    public init(executable: URL, root: URL = Paths.root) { self.executable = executable; self.root = root }

    public func fetch(account: Account, now: Date) async throws -> Snapshot {
        guard account.usesExistingClaude != true else { throw UsageError.claudeDedicatedSignInRequired }
        let connection = ClaudeConnection(root: root, executable: executable, bundledBridge: executable)
        let identity = try await connection.authIdentity(account: account)
        guard identity.signedIn, let before = CodexIdentity.normalized(identity.email) else { throw UsageError.authentication }
        if let expected = CodexIdentity.normalized(account.expectedIdentity), expected != before {
            throw UsageError.accountChanged(expected)
        }
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
            return try ClaudeUsageReport.parse(result.data, at: Date())
        }
        var snapshot = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        // /usage runs separately from auth status. A sign-in change during that
        // interval must invalidate the reading rather than relabel another account.
        let after = try await connection.authIdentity(account: account)
        guard after.signedIn, CodexIdentity.normalized(after.email) == before, after.orgID == identity.orgID else {
            throw UsageError.accountChanged(account.expectedIdentity ?? before)
        }
        snapshot.identity = before
        return snapshot
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
        // Verified Ultra accounts omit the session row. The all-model weekly row
        // remains authoritative; model-only or behavioral reports are insufficient.
        guard ids.contains("week.all models") else {
            throw UsageError.unavailable("Claude Code did not return an all-model weekly limit. Open /usage in this account’s Claude Code profile and retry. If /usage is unsupported, update Claude Code.")
        }
        return Snapshot(observedAt: now, windows: windows, source: "Claude Code /usage",
                        note: "Read directly from Claude’s plan-usage command. No conversation or open Terminal is needed for updates.")
    }

    private static let resetClock = try! NSRegularExpression(
        pattern: #"^(?:(?:([a-z]{3}) (\d{1,2})|([a-z]{3,9})) at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#,
        options: .caseInsensitive)
    static func resetDate(_ value: String, now: Date) -> Date? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var zone = TimeZone.current
        var raw = input
        if let start = input.lastIndex(of: "("), input.hasSuffix(")") {
            let name = String(input[input.index(after: start)..<input.index(before: input.endIndex)])
            guard let reportedZone = TimeZone(identifier: name) ?? TimeZone(abbreviation: name) else { return nil }
            zone = reportedZone
            raw = String(input[..<start]).trimmingCharacters(in: .whitespaces)
        }
        func valid(_ date: Date?) -> Date? {
            guard let date, date > now.addingTimeInterval(-60), date < now.addingTimeInterval(8 * 86400) else { return nil }
            return date
        }
        if let iso = valid(ISO8601DateFormatter().date(from: raw)) { return iso }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        // Parse the clock once. Trying date-format permutations for each of the
        // next eight days repeatedly constructs ICU formatters during a refresh.
        let text = raw.lowercased() as NSString
        guard let match = resetClock.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { return nil }
        func part(_ i: Int) -> String? {
            let range = match.range(at: i)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }
        guard var hour = part(4).flatMap(Int.init) else { return nil }
        let minute = part(5).flatMap(Int.init) ?? 0
        guard minute < 60 else { return nil }
        if let suffix = part(6) {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (suffix == "pm" ? 12 : 0)
        } else if hour >= 24 || part(5) == nil { return nil }

        var target = DateComponents()
        target.hour = hour; target.minute = minute; target.second = 0
        if let month = part(1), let day = part(2).flatMap(Int.init) {
            let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let index = names.firstIndex(of: month), (1...31).contains(day) else { return nil }
            target.month = index + 1; target.day = day
        } else if let weekday = part(3) {
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            guard let index = names.firstIndex(where: { $0 == weekday || String($0.prefix(3)) == weekday }) else { return nil }
            target.weekday = index + 1
        }
        // Search only the supported eight-day horizon, including across New Year.
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard target.month.map({ $0 == parts.month }) != false,
                  target.day.map({ $0 == parts.day }) != false,
                  target.weekday.map({ $0 == parts.weekday }) != false else { continue }
            var clock = parts
            clock.weekday = nil; clock.hour = hour; clock.minute = minute; clock.second = 0
            if let date = valid(calendar.date(from: clock)), calendar.component(.hour, from: date) == hour { return date }
        }
        return nil
    }
}
