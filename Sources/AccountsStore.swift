import Foundation
import Combine

/// Owns the dynamic list of Claude accounts. Each account is a `UsageService` keyed by a profile
/// string; the profile also names its token file (`tokens.json` for "default", `tokens-<profile>.json`
/// otherwise) and its usage cache. The profile order is persisted so accounts survive restarts.
@MainActor
final class AccountsStore: ObservableObject {
    @Published private(set) var services: [UsageService]

    private let profilesKey = "accountProfiles"
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.services = AccountsStore.loadProfiles().map { UsageService(profile: $0) }
        resubscribe()
    }

    /// Re-broadcast each account's changes as our own, so a single `@ObservedObject AccountsStore`
    /// in the view re-renders when any account's published state changes (arrays of ObservableObjects
    /// aren't observed element-wise otherwise).
    private func resubscribe() {
        cancellables.removeAll()
        for service in services {
            service.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// Persisted profile order, migrating from the old fixed default/secondary layout on first run.
    private static func loadProfiles() -> [String] {
        if let saved = UserDefaults.standard.stringArray(forKey: "accountProfiles"), !saved.isEmpty {
            return saved
        }
        var initial = ["default"]
        if TokenStore.exists(profile: "secondary") {
            initial.append("secondary")
        }
        UserDefaults.standard.set(initial, forKey: "accountProfiles")
        return initial
    }

    private func saveProfiles() {
        UserDefaults.standard.set(services.map { $0.profile }, forKey: profilesKey)
    }

    func startAll() {
        for service in services { service.startPolling() }
    }

    func restartAll() {
        for service in services { service.restartPolling() }
    }

    func refreshAll() async {
        for service in services { await service.fetchUsage() }
    }

    /// Adds a fresh, signed-out account and starts it. Caller triggers the login flow on the result.
    @discardableResult
    func addAccount() -> UsageService {
        let profile = "acct-" + UUID().uuidString.prefix(8).lowercased()
        let service = UsageService(profile: profile)
        services.append(service)
        resubscribe()
        saveProfiles()
        service.startPolling()
        return service
    }

    func removeAccount(_ service: UsageService) {
        service.logout()
        services.removeAll { $0.profile == service.profile }
        resubscribe()
        saveProfiles()
    }
}
