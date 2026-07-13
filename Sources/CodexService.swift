import Foundation

// MARK: - Codex rate-limit window

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
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
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

    /// Adapts a (weekly) window into a UsageBucket so it can reuse the shared pace / action messages.
    var pacingBucket: UsageBucket? {
        guard let date = resetDate else { return nil }
        return UsageBucket(utilization: usedPercent, resetsAt: ISO8601DateFormatter().string(from: date))
    }
}

private struct CodexSnapshot {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let planType: String?
    let date: Date?   // nil == live (from API now); non-nil == local-log snapshot time
}

/// Reads Codex usage. Primary source is the live ChatGPT backend (`wham/usage`) using the
/// OAuth token in `~/.codex/auth.json` — same call the `codex` CLI makes — so the 5-hour and
/// weekly percentages match reality even while Codex is idle. Falls back to parsing the local
/// rollout logs (`~/.codex/sessions/**/rollout-*.jsonl`) when the API is unreachable or the
/// stored token has expired (in which case the value is "as of the last Codex run").
///
/// Auth is owned by the `codex` CLI (we only read/refresh auth.json), so there is deliberately
/// no in-app Codex login/logout — the CODEX toggle only controls visibility. Never delete auth.json.
@MainActor
final class CodexService: ObservableObject {
    @Published var primary: CodexWindow?    // short (5-hour) window — nil on weekly-only plans
    @Published var secondary: CodexWindow?  // weekly window
    @Published var planType: String?
    @Published var snapshotDate: Date?      // set only for the local-log fallback
    @Published var isLive = false
    @Published var available = false

    private let codexDir: URL
    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private let userAgent = "codex_cli_rs/0.73.0"
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
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        if let snap = await fetchFromAPI() {
            apply(snap)
            Log.info("Codex(API): 5h=\(primary?.percentage ?? -1)% weekly=\(secondary?.percentage ?? -1)% plan=\(planType ?? "?")")
        } else if let snap = scanLocal() {
            apply(snap)
            Log.info("Codex(log): 5h=\(primary?.percentage ?? -1)% weekly=\(secondary?.percentage ?? -1)% asOf=\(snapshotText ?? "?")")
        } else {
            available = false
            Log.info("Codex: no data (API and local log both unavailable)")
        }
    }

    private func apply(_ snap: CodexSnapshot) {
        primary = snap.primary
        secondary = snap.secondary
        planType = snap.planType
        snapshotDate = snap.date
        isLive = (snap.date == nil)
        available = (snap.primary != nil || snap.secondary != nil)
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

    /// Snapshot time for the local-log fallback ("as of …"); nil when live.
    var snapshotText: String? {
        guard let date = snapshotDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Live API (chatgpt.com/backend-api/wham/usage)

    private func fetchFromAPI() async -> CodexSnapshot? {
        guard let auth = readAuth() else { return nil }
        let first = await requestUsage(token: auth.token, account: auth.account)
        if let snapshot = first.snapshot { return snapshot }
        guard first.status == 401 else { return nil }

        // Stored token expired — refresh it (rotating the refresh token in auth.json) and retry once.
        Log.info("Codex: usage 401, refreshing token")
        guard let newToken = await refreshToken() else { return nil }
        return await requestUsage(token: newToken, account: auth.account).snapshot
    }

    private func requestUsage(token: String, account: String) async -> (snapshot: CodexSnapshot?, status: Int) {
        var request = URLRequest(url: URL(string: usageURL)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return (nil, 0) }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = json["rate_limit"] as? [String: Any] else { return (nil, http.statusCode) }

        let (primary, secondary) = CodexService.classify([
            CodexService.apiWindow(rateLimit["primary_window"]),
            CodexService.apiWindow(rateLimit["secondary_window"]),
        ])
        guard primary != nil || secondary != nil else { return (nil, http.statusCode) }
        let snapshot = CodexSnapshot(
            primary: primary,
            secondary: secondary,
            planType: json["plan_type"] as? String,
            date: nil
        )
        return (snapshot, 200)
    }

    /// Refreshes the ChatGPT OAuth token via auth.openai.com and writes the rotated tokens back to
    /// `auth.json` so the `codex` CLI stays in sync (its refresh token would otherwise be invalidated).
    private func refreshToken() async -> String? {
        let authFile = codexDir.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authFile),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = json["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
        ])

        guard let (respData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let resp = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let newAccess = resp["access_token"] as? String, !newAccess.isEmpty else {
            Log.error("Codex: token refresh failed")
            return nil
        }

        tokens["access_token"] = newAccess
        if let newRefresh = resp["refresh_token"] as? String, !newRefresh.isEmpty {
            tokens["refresh_token"] = newRefresh
        }
        if let newId = resp["id_token"] as? String, !newId.isEmpty {
            tokens["id_token"] = newId
        }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try out.write(to: authFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
            } catch {
                Log.error("Codex: auth.json write failed: \(error.localizedDescription)")
            }
        }
        Log.info("Codex: token refreshed")
        return newAccess
    }

    private func readAuth() -> (token: String, account: String)? {
        let authFile = codexDir.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty else { return nil }
        return (token, account)
    }

    /// Sorts windows into the short (5-hour) vs weekly slot by their length, rather than by their
    /// position in the response. OpenAI moved some plans to a weekly-only limit and now delivers it
    /// in `primary_window`; classifying by length keeps it labelled "Weekly" and leaves the 5-hour
    /// slot empty, while still handling the older 5-hour + weekly shape.
    private static func classify(_ windows: [CodexWindow?]) -> (primary: CodexWindow?, weekly: CodexWindow?) {
        var short: CodexWindow?
        var weekly: CodexWindow?
        for case let window? in windows {
            if let minutes = window.windowMinutes, minutes >= 1440 {
                weekly = weekly ?? window
            } else {
                short = short ?? window
            }
        }
        return (short, weekly)
    }

    private static func apiWindow(_ any: Any?) -> CodexWindow? {
        guard let dict = any as? [String: Any],
              let pct = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let windowMinutes = (dict["limit_window_seconds"] as? NSNumber).map { $0.intValue / 60 }
        return CodexWindow(
            usedPercent: pct,
            windowMinutes: windowMinutes,
            resetsAt: (dict["reset_at"] as? NSNumber)?.intValue
        )
    }

    // MARK: - Local rollout-log fallback

    private func scanLocal() -> CodexSnapshot? {
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
            guard line.contains("\"token_count\"") else { return }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any] else { return }

            let (primary, secondary) = CodexService.classify([
                CodexService.logWindow(from: rateLimits["primary"]),
                CodexService.logWindow(from: rateLimits["secondary"]),
            ])
            let plan = rateLimits["plan_type"] as? String
            let date = (obj["timestamp"] as? String).flatMap { CodexService.parseDate($0) }
            snapshot = CodexSnapshot(primary: primary, secondary: secondary, planType: plan, date: date)
        }
        return snapshot
    }

    private static func logWindow(from any: Any?) -> CodexWindow? {
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
