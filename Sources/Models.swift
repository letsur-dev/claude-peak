import Foundation

// MARK: - Account Info

struct AccountInfo {
    let email: String?
    let rateLimitTier: String?
    let ravenType: String?
    let billingType: String?

    var planLabel: String? {
        guard let tier = rateLimitTier else { return nil }
        switch tier {
        case "default_claude_max_20x": return "Max 20x"
        case "default_claude_max_5x": return "Max 5x"
        case "default_claude_max": return "Max"
        case "default_claude_pro": return "Pro"
        case "default_claude_ai": return "Free"
        case "default_raven":  // newer subscription line; sub-plan is in raven_type
            switch ravenType {
            case "team": return "Team"
            case "max": return "Max"
            case "pro": return "Pro"
            default: return ravenType.map { $0.capitalized } ?? "Team"
            }
        default: return nil
        }
    }

    /// Higher = better plan. Used to pick which org to show when an account belongs to several
    /// (e.g. a free personal org plus a paid team org). Unknown/API-eval tiers rank lowest.
    static func tierRank(_ tier: String?) -> Int {
        switch tier {
        case "default_claude_max_20x": return 100
        case "default_claude_max_5x": return 90
        case "default_claude_max": return 80
        case "default_raven": return 70
        case "default_claude_pro": return 60
        case "default_claude_ai": return 10
        default: return 0
        }
    }
}

// MARK: - Usage API Response

struct UsageResponse: Codable {
    let fiveHour: UsageBucket
    let sevenDay: UsageBucket
    let sevenDaySonnet: UsageBucket?
    let extraUsage: ExtraUsage
    let limits: [Limit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }

    /// Model-scoped weekly limits (e.g. "Fable only") from the new `limits` array.
    /// The legacy per-model top-level fields are now always null, so these come from `limits`.
    var weeklyScopedLimits: [ScopedLimit] {
        guard let limits = limits else { return [] }
        return limits.compactMap { limit in
            guard limit.group == "weekly", limit.kind == "weekly_scoped",
                  let name = limit.scope?.model?.displayName else { return nil }
            return ScopedLimit(
                name: name,
                bucket: UsageBucket(utilization: Double(limit.percent), resetsAt: limit.resetsAt)
            )
        }
    }
}

struct UsageBucket: Codable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetDate: Date? {
        guard let resetsAt = resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }

    var timeUntilReset: String {
        guard let resetDate = resetDate else { return "—" }
        let interval = resetDate.timeIntervalSinceNow
        guard interval > 0 else { return "now" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var resetDateString: String {
        guard let resetDate = resetDate else { return "—" }
        guard resetDate.timeIntervalSinceNow > 0 else { return "now" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d(EEE) HH:mm"
        return formatter.string(from: resetDate)
    }

    /// Countdown trimmed to one unit for the menu bar ("3h", "45m", "6d"): with several accounts
    /// a full "3h 20m" per account is too wide. Rounded down, so it never overstates what is left.
    var shortTimeUntilReset: String {
        UsageBucket.shortDuration(resetDate?.timeIntervalSinceNow)
    }

    static func shortDuration(_ interval: TimeInterval?) -> String {
        guard let interval = interval else { return "" }
        guard interval > 0 else { return "now" }
        if interval >= 86400 { return "\(Int(interval) / 86400)d" }
        if interval >= 3600 { return "\(Int(interval) / 3600)h" }
        return "\(max(1, Int(interval) / 60))m"
    }

    var percentage: Int {
        min(100, Int(utilization))
    }

    /// Pace ratio: actual usage / expected usage based on elapsed time in 7-day window
    var paceRatio: Double? {
        guard let resetDate = resetDate else { return nil }
        let timeUntil = resetDate.timeIntervalSinceNow
        guard timeUntil > 0 else { return nil }
        let totalWindow: Double = 7 * 86400
        let elapsed = totalWindow - timeUntil
        guard elapsed > 0 else { return nil }
        let expectedUtilization = max((elapsed / totalWindow) * 100, 5.0)
        return utilization / expectedUtilization
    }

    func paceMessage(language: AppLanguage) -> String? {
        guard let ratio = paceRatio else { return nil }
        if language == .ko {
            if ratio < 0.3 { return "마구 난사해도 됨" }
            if ratio < 0.6 { return "여유 넘침" }
            if ratio < 0.85 { return "적당히 쓰는 중" }
            if ratio < 1.1 { return "딱 맞는 페이스" }
            if ratio < 1.4 { return "슬슬 걱정된다잉" }
            if ratio < 1.7 { return "이러다 거덜남" }
            return "거덜직전"
        }
        if ratio < 0.3 { return "Go absolutely wild" }
        if ratio < 0.6 { return "Plenty of room" }
        if ratio < 0.85 { return "Cruising nicely" }
        if ratio < 1.1 { return "Right on pace" }
        if ratio < 1.4 { return "Getting warm" }
        if ratio < 1.7 { return "Burning hot" }
        return "Hit the brakes!"
    }

    func actionMessage(language: AppLanguage) -> String? {
        guard let resetDate = resetDate else { return nil }
        let timeUntil = resetDate.timeIntervalSinceNow
        guard timeUntil > 0 else { return nil }
        let remaining = 100.0 - utilization
        let daysLeft = timeUntil / 86400
        let hoursLeft = timeUntil / 3600
        let ko = language == .ko

        // Urgent: reset imminent, budget wasted
        if hoursLeft < 1 && remaining > 5 {
            return ko ? "\(Int(remaining))% 버린다! 지금 당장!" : "\(Int(remaining))% wasted! Use it NOW!"
        }
        if hoursLeft < 6 && remaining > 10 {
            return ko ? "\(Int(remaining))% 남았는데 곧 리셋! 태워라" : "\(Int(remaining))% left, reset soon! Burn it"
        }
        if hoursLeft < 24 && remaining > 20 {
            return ko ? "내일 리셋인데 \(Int(remaining))% 남음. 써!" : "\(Int(remaining))% left, resets tomorrow. Use it!"
        }

        // Normal pace-based advice
        guard let ratio = paceRatio else { return nil }
        if daysLeft <= 0 { return nil }
        let dailyBudget = remaining / daysLeft
        let todayTarget = min(100, Int(utilization + dailyBudget))
        let todayLimit = max(0, Int(utilization + dailyBudget * 0.5))

        if ratio < 0.6 {
            return ko ? "오늘 \(todayTarget)%까지 OK" : "Today up to \(todayTarget)% is fine"
        }
        if ratio < 1.1 {
            return ko ? "이 페이스 유지하면 딱" : "Keep this pace"
        }
        if ratio < 1.7 {
            return ko ? "오늘은 \(todayLimit)% 이하로" : "Stay under \(todayLimit)% today"
        }
        return ko ? "오늘은 쉬는 게..." : "Maybe take a break today..."
    }

    func paceColor() -> String {
        guard let ratio = paceRatio else { return "secondary" }
        if ratio < 0.6 { return "green" }
        if ratio < 1.1 { return "secondary" }
        if ratio < 1.4 { return "orange" }
        return "red"
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
    }
}

// MARK: - Model-scoped Limits (new `limits` API array)

struct Limit: Codable {
    let kind: String        // "session" | "weekly_all" | "weekly_scoped"
    let group: String       // "session" | "weekly"
    let percent: Int
    let severity: String?
    let resetsAt: String?
    let scope: LimitScope?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }
}

struct LimitScope: Codable {
    let model: LimitModel?
}

struct LimitModel: Codable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct ScopedLimit: Identifiable {
    var id: String { name }
    let name: String
    let bucket: UsageBucket
}
