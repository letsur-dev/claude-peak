import AppKit
import ServiceManagement

/// "Launch at login" via SMAppService (macOS 13+). The system's login-item registration is the
/// source of truth, so nothing is stored in UserDefaults: if the user removes the app from
/// System Settings › General › Login Items, the toggle reflects that on next refresh.
/// Only used from the UI (main thread).
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled = false
    /// macOS registered the item but the user must allow it in System Settings.
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    /// Status when `lastError` was set; the error is cleared once the status moves on.
    private var statusAtError: SMAppService.Status?
    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        // The popover's view is reused, so `.onAppear` doesn't fire again after the user comes
        // back from System Settings (e.g. having approved the login item). Re-read the status
        // whenever the app becomes active or a window (the popover) becomes key.
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        if let failed = statusAtError, failed != status {
            lastError = nil
            statusAtError = nil
        }
        let enabled = status == .enabled || status == .requiresApproval
        let approval = status == .requiresApproval
        if isEnabled != enabled { isEnabled = enabled }
        if needsApproval != approval { needsApproval = approval }
    }

    func set(_ enabled: Bool) {
        lastError = nil
        statusAtError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("Launch at login \(enabled ? "enabled" : "disabled"), status=\(SMAppService.mainApp.status.rawValue)")
        } catch {
            lastError = error.localizedDescription
            statusAtError = SMAppService.mainApp.status
            Log.error("Launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
