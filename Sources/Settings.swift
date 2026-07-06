import Foundation

enum MenuBarDisplay: String, CaseIterable {
    case percentOnly = "percent"
    case timeOnly = "time"
    case both = "both"

    var label: String {
        switch self {
        case .percentOnly: return "Percentage only"
        case .timeOnly: return "Time only"
        case .both: return "Both"
        }
    }
}

enum FlameMode: String, CaseIterable {
    case off = "off"
    case single = "single"
    case dynamic = "dynamic"
    case madmax = "madmax"

    var label: String {
        switch self {
        case .off: return "Off"
        case .single: return "1"
        case .dynamic: return "3"
        case .madmax: return "MAX"
        }
    }

    static var pickerCases: [FlameMode] {
        [.off, .single, .dynamic]
    }
}

enum AppLanguage: String, CaseIterable {
    case en = "en"
    case ko = "ko"

    var label: String {
        switch self {
        case .en: return "EN"
        case .ko: return "한"
        }
    }
}

enum PollingInterval: Int, CaseIterable {
    case five = 300
    case ten = 600

    var label: String {
        switch self {
        case .five: return "5 min"
        case .ten: return "10 min"
        }
    }
}

enum WeeklyLimitDisplay: String, CaseIterable {
    case all = "all"
    case scoped = "scoped"
    case both = "both"

    var label: String {
        switch self {
        case .all: return "All"
        case .scoped: return "Scoped"
        case .both: return "Both"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var menuBarDisplay: MenuBarDisplay {
        didSet { UserDefaults.standard.set(menuBarDisplay.rawValue, forKey: "menuBarDisplay") }
    }
    @Published var pollingInterval: PollingInterval {
        didSet { UserDefaults.standard.set(pollingInterval.rawValue, forKey: "pollingInterval") }
    }
    @Published var flameMode: FlameMode {
        didSet { UserDefaults.standard.set(flameMode.rawValue, forKey: "flameMode") }
    }
    @Published var remoteEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteEnabled, forKey: "remoteEnabled") }
    }
    @Published var remoteHost: String {
        didSet { UserDefaults.standard.set(remoteHost, forKey: "remoteHost") }
    }
    @Published var remotePort: Int {
        didSet { UserDefaults.standard.set(remotePort, forKey: "remotePort") }
    }
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }
    @Published var weeklyLimitDisplay: WeeklyLimitDisplay {
        didSet { UserDefaults.standard.set(weeklyLimitDisplay.rawValue, forKey: "weeklyLimitDisplay") }
    }
    @Published var codexEnabled: Bool {
        didSet { UserDefaults.standard.set(codexEnabled, forKey: "codexEnabled") }
    }
    @Published var mainAccountLabel: String {
        didSet { UserDefaults.standard.set(mainAccountLabel, forKey: "mainAccountLabel") }
    }
    @Published var subAccountLabel: String {
        didSet { UserDefaults.standard.set(subAccountLabel, forKey: "subAccountLabel") }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "menuBarDisplay"),
           let value = MenuBarDisplay(rawValue: raw) {
            self.menuBarDisplay = value
        } else {
            self.menuBarDisplay = .both
        }

        let interval = UserDefaults.standard.integer(forKey: "pollingInterval")
        if interval > 0, let value = PollingInterval(rawValue: interval) {
            self.pollingInterval = value
        } else {
            self.pollingInterval = .five
        }

        if let raw = UserDefaults.standard.string(forKey: "flameMode"),
           let value = FlameMode(rawValue: raw) {
            self.flameMode = value
        } else {
            self.flameMode = .dynamic
        }

        self.remoteEnabled = UserDefaults.standard.bool(forKey: "remoteEnabled")

        if let host = UserDefaults.standard.string(forKey: "remoteHost"), !host.isEmpty {
            self.remoteHost = host
        } else {
            self.remoteHost = ""
        }

        let port = UserDefaults.standard.integer(forKey: "remotePort")
        self.remotePort = port > 0 ? port : 3200

        if let raw = UserDefaults.standard.string(forKey: "language"),
           let value = AppLanguage(rawValue: raw) {
            self.language = value
        } else {
            self.language = .en
        }

        self.mainAccountLabel = UserDefaults.standard.string(forKey: "mainAccountLabel") ?? "Main"
        self.subAccountLabel = UserDefaults.standard.string(forKey: "subAccountLabel") ?? "Sub"

        if let raw = UserDefaults.standard.string(forKey: "weeklyLimitDisplay"),
           let value = WeeklyLimitDisplay(rawValue: raw) {
            self.weeklyLimitDisplay = value
        } else {
            self.weeklyLimitDisplay = .both
        }

        if UserDefaults.standard.object(forKey: "codexEnabled") != nil {
            self.codexEnabled = UserDefaults.standard.bool(forKey: "codexEnabled")
        } else {
            self.codexEnabled = true
        }
    }
}
