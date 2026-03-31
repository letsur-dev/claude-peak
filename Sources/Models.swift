import Foundation

// MARK: - Usage API Response

struct UsageResponse: Codable {
    let fiveHour: UsageBucket
    let sevenDay: UsageBucket
    let sevenDaySonnet: UsageBucket?
    let extraUsage: ExtraUsage

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
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
        guard elapsed > 3600 else { return nil } // need at least 1h of data
        let expectedUtilization = (elapsed / totalWindow) * 100
        guard expectedUtilization > 0 else { return nil }
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
