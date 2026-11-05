import Foundation
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

    private init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("Launch at login \(enabled ? "enabled" : "disabled"), status=\(SMAppService.mainApp.status.rawValue)")
        } catch {
            lastError = error.localizedDescription
            Log.error("Launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
