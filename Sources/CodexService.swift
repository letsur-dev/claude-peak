import Foundation

// MARK: - Codex rate-limit window (from ~/.codex rollout logs)

struct CodexWindow {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Int?   // unix seconds

    var percentage: Int { min(100, Int(usedPercent.rounded())) }

    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: Double($0)) } }

    var timeUntilReset: String {
        guard let date = resetDate else { return "—" }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "now" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var resetDateString: String {
        guard let date = resetDate else { return "—" }
        guard date.timeIntervalSinceNow > 0 else { return "now" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d(EEE) HH:mm"
        return formatter.string(from: date)
    }
}

private struct CodexSnapshot {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let planType: String?
    let date: Date?
}

/// Reads Codex usage from local rollout logs (`~/.codex/sessions/**/rollout-*.jsonl`).
/// The Codex CLI writes the server's own rate-limit snapshot (5-hour + weekly windows)
/// into each `token_count` event, so we just read the latest one — no auth, no network.
/// Freshness is "as of the last Codex turn"; it does not update while Codex is idle.
@MainActor
final class CodexService: ObservableObject {
    @Published var primary: CodexWindow?    // 5-hour window
    @Published var secondary: CodexWindow?  // weekly window
    @Published var planType: String?
    @Published var snapshotDate: Date?
    @Published var available = false

    private let codexDir: URL
    private var timer: Timer?

    init() {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            codexDir = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            codexDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
        }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let snap = scan()
        primary = snap?.primary
        secondary = snap?.secondary
        planType = snap?.planType
        snapshotDate = snap?.date
        available = (snap?.primary != nil || snap?.secondary != nil)
    }

    var planLabel: String? {
        guard let plan = planType else { return nil }
        switch plan {
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "business": return "Business"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return plan.capitalized
        }
    }

    var snapshotText: String? {
        guard let date = snapshotDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Scanning

    private func scan() -> CodexSnapshot? {
        let sessions = codexDir.appendingPathComponent("sessions")
        guard let newest = newestRollout(in: sessions) else { return nil }
        return lastTokenCount(in: newest)
    }

    private func newestRollout(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (url: URL, date: Date)?
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.hasPrefix("rollout-") else { continue }
            let mod = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || mod > best!.date {
                best = (fileURL, mod)
            }
        }
        return best?.url
    }

    private func lastTokenCount(in url: URL) -> CodexSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var snapshot: CodexSnapshot?
        text.enumerateLines { line, _ in
            // Fast pre-filter: skip the large schema lines, only parse token_count events.
            guard line.contains("\"token_count\"") else { return }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any] else { return }

            let primary = CodexService.window(from: rateLimits["primary"])
            let secondary = CodexService.window(from: rateLimits["secondary"])
            let plan = rateLimits["plan_type"] as? String
            let date = (obj["timestamp"] as? String).flatMap { CodexService.parseDate($0) }
            snapshot = CodexSnapshot(primary: primary, secondary: secondary, planType: plan, date: date)
        }
        return snapshot
    }

    private static func window(from any: Any?) -> CodexWindow? {
        guard let dict = any as? [String: Any],
              let pct = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        return CodexWindow(
            usedPercent: pct,
            windowMinutes: (dict["window_minutes"] as? NSNumber)?.intValue,
            resetsAt: (dict["resets_at"] as? NSNumber)?.intValue
        )
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
