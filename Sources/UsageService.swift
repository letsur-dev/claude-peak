import Foundation

@MainActor
final class UsageService: ObservableObject, Identifiable {
    nonisolated var id: String { profile }
    @Published var usage: UsageResponse?
    @Published var error: String?
    @Published var isLoading = false
    @Published var needsLogin = false
    @Published var usageDelta: Double = 0 // change per poll
    @Published var email: String?
    @Published var accountInfo: AccountInfo?

    /// Plan badge text. Ultra reports the Max 20x rate-limit tier and no distinct capability
    /// (just "claude_max", "chat"); unlike Max 20x it has no 5-hour session limit, so use that.
    var planLabel: String? {
        if accountInfo?.rateLimitTier == "default_claude_max_20x", usage?.hasSessionLimit == false {
            return "Ultra"
        }
        return accountInfo?.planLabel
    }
    @Published var lastUpdated: Date?   // time of the last successful fetch (or cached snapshot)
    @Published var isStale = false      // most recent refresh failed but cached data is still shown

    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let tokenUrl = "https://platform.claude.com/v1/oauth/token"
    private let usageUrl = "https://api.anthropic.com/api/oauth/usage"
    private let accountUrl = "https://api.anthropic.com/api/oauth/account"
    private let userAgent = "claude-code/2.0.32"
    private let scopes = "user:profile user:inference"

    private var cachedAccessToken: String?
    private var tokenExpiresAt: Date?
    private var pollingTimer: Timer?
    private var resetTimer: Timer?
    /// Bumped on logout and login. Async work captures it when it starts and drops its result
    /// if it changed meanwhile, so a request that began before a logout can't restore usage,
    /// account info, or a token that the logout deleted.
    private var sessionGeneration = 0

    let profile: String
    let oauthService = OAuthService()

    init(profile: String = "default") {
        self.profile = profile
    }

    private var cacheKey: String { "cachedUsage-\(profile)" }
    private var cacheDateKey: String { "cachedUsageDate-\(profile)" }

    private func loadCachedUsage() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(UsageResponse.self, from: data) else { return }
        self.usage = cached
        self.lastUpdated = UserDefaults.standard.object(forKey: cacheDateKey) as? Date
    }

    private func cacheUsage(_ usage: UsageResponse) {
        if let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: cacheDateKey)
        }
    }

    func startPolling() {
        guard pollingTimer == nil else { return }
        loadCachedUsage()
        if let stored = try? TokenStore.load(profile: profile) {
            self.email = stored.email
        }
        Task { await fetchUsage() }
        let interval = TimeInterval(AppSettings.shared.pollingInterval.rawValue)
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchUsage()
            }
        }
    }

    func restartPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        startPolling()
    }

    private func scheduleResetFetch(_ usage: UsageResponse) {
        resetTimer?.invalidate()
        resetTimer = nil

        guard let resetDate = usage.fiveHour.resetDate else { return }
        let delay = resetDate.timeIntervalSinceNow
        guard delay > 0 else { return }

        resetTimer = Timer.scheduledTimer(withTimeInterval: delay + 2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                Log.info("5-hour reset time reached, fetching fresh usage")
                await self?.fetchUsage()
            }
        }
    }

    func logout() {
        sessionGeneration += 1
        TokenStore.clear(profile: profile)
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheDateKey)
        cachedAccessToken = nil
        tokenExpiresAt = nil
        resetTimer?.invalidate()
        resetTimer = nil
        usage = nil
        error = nil
        needsLogin = true
        email = nil
        accountInfo = nil
    }

    func handleLoginResult(_ result: Result<TokenPair, Error>) {
        switch result {
        case .failure(let error):
            self.error = error.localizedDescription
            Log.error("OAuth login failed: \(error.localizedDescription)")
            return
        case .success(let pair):
            Log.info("OAuth login succeeded, expires_in=\(pair.expiresIn)s")
            handleLoginSuccess(pair)
        }
    }

    private func handleLoginSuccess(_ pair: TokenPair) {
        let tokens = StoredTokens(
            accessToken: pair.accessToken,
            refreshToken: pair.refreshToken,
            expiresAt: Int64((Date().timeIntervalSince1970 + Double(pair.expiresIn)) * 1000),
            email: pair.email,
            organizationUUID: pair.organizationUUID,
            organizationName: pair.organizationName
        )
        do {
            sessionGeneration += 1
            try TokenStore.save(tokens, profile: profile)
            self.cachedAccessToken = pair.accessToken
            self.tokenExpiresAt = Date().addingTimeInterval(Double(pair.expiresIn))
            self.needsLogin = false
            self.error = nil
            Task { await fetchUsage() }
        } catch {
            self.error = "Failed to save tokens"
        }
    }

    func fetchUsage() async {
        isLoading = true
        defer { isLoading = false }
        let generation = sessionGeneration

        do {
            let token = try await getValidAccessToken()
            let usageData = try await requestUsage(token: token)
            guard generation == sessionGeneration else { return }
            let previousUtilization = self.usage?.fiveHour.utilization ?? usageData.fiveHour.utilization
            self.usageDelta = max(0, usageData.fiveHour.utilization - previousUtilization)
            self.usage = usageData
            self.error = nil
            self.needsLogin = false
            self.isStale = false
            self.lastUpdated = Date()
            cacheUsage(usageData)
            scheduleResetFetch(usageData)
            if accountInfo == nil { await fetchAccountInfo(token: token, generation: generation) }
            Log.info("Usage fetched: 5h=\(usageData.fiveHour.utilization)%, 7d=\(usageData.sevenDay.utilization)%")
        } catch where generation != sessionGeneration {
            // Logged out or in again while this request was running; its outcome is stale.
            Log.info("Dropping stale usage result after logout/login")
        } catch is TokenStoreError {
            self.needsLogin = true
            self.error = nil
            Log.info("No token found, login required")
        } catch UsageServiceError.unauthorized {
            self.cachedAccessToken = nil
            self.tokenExpiresAt = nil
            Log.error("Token unauthorized, attempting refresh")
            do {
                let token = try await refreshAndRetry()
                let usageData = try await requestUsage(token: token)
                guard generation == sessionGeneration else { return }
                self.usage = usageData
                self.error = nil
                self.isStale = false
                self.lastUpdated = Date()
                cacheUsage(usageData)
                scheduleResetFetch(usageData)
                Log.info("Refresh succeeded, usage: 5h=\(usageData.fiveHour.utilization)%")
            } catch {
                guard generation == sessionGeneration else { return }
                self.needsLogin = true
                self.error = "Session expired. Please login again."
                TokenStore.clear(profile: profile)
                Log.error("Refresh failed: \(error.localizedDescription)")
            }
        } catch UsageServiceError.usageFetchFailed(429) {
            if self.usage == nil {
                self.error = "Rate limited. Will retry shortly."
            } else {
                self.isStale = true
            }
            Log.info("Rate limited (429), keeping previous data")
        } catch UsageServiceError.tokenRefreshFailed {
            self.needsLogin = true
            self.usage = nil
            TokenStore.clear(profile: profile)
            Log.error("Token refresh failed, re-login required")
        } catch {
            self.error = error.localizedDescription
            Log.error("fetchUsage failed: \(error.localizedDescription)")
        }
    }

    private func getValidAccessToken() async throws -> String {
        if let token = cachedAccessToken, let expiresAt = tokenExpiresAt,
           expiresAt.timeIntervalSinceNow > 300 {
            return token
        }

        let stored = try TokenStore.load(profile: profile)
        let expiry = Date(timeIntervalSince1970: TimeInterval(stored.expiresAt) / 1000)

        if expiry.timeIntervalSinceNow > 300 {
            self.cachedAccessToken = stored.accessToken
            self.tokenExpiresAt = expiry
            return stored.accessToken
        }

        // Token expired, try refresh
        if let refreshToken = stored.refreshToken, !refreshToken.isEmpty {
            return try await refreshAccessToken(refreshToken: refreshToken)
        }

        throw TokenStoreError.noToken
    }

    private func refreshAndRetry() async throws -> String {
        let stored = try TokenStore.load(profile: profile)
        guard let refreshToken = stored.refreshToken, !refreshToken.isEmpty else {
            throw TokenStoreError.noToken
        }
        return try await refreshAccessToken(refreshToken: refreshToken)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        let generation = sessionGeneration
        var request = URLRequest(url: URL(string: tokenUrl)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
            "scope": scopes,
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UsageServiceError.tokenRefreshFailed
        }

        struct RefreshResponse: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
        }

        let refreshResp = try JSONDecoder().decode(RefreshResponse.self, from: data)
        // A logout during the request deleted the token; don't write a fresh one back.
        guard generation == sessionGeneration else { throw CancellationError() }
        let previous = try? TokenStore.load(profile: profile)
        let newTokens = StoredTokens(
            accessToken: refreshResp.access_token,
            refreshToken: refreshResp.refresh_token ?? refreshToken,
            expiresAt: Int64((Date().timeIntervalSince1970 + Double(refreshResp.expires_in)) * 1000),
            email: previous?.email,
            organizationUUID: previous?.organizationUUID,
            organizationName: previous?.organizationName
        )
        try TokenStore.save(newTokens, profile: profile)

        self.cachedAccessToken = refreshResp.access_token
        self.tokenExpiresAt = Date().addingTimeInterval(Double(refreshResp.expires_in))
        return refreshResp.access_token
    }

    private func requestUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: URL(string: usageUrl)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageServiceError.usageFetchFailed(0)
        }

        if let rawBody = String(data: data, encoding: .utf8) {
            Log.info("Usage API HTTP \(httpResponse.statusCode): \(rawBody)")
        }

        if httpResponse.statusCode == 401 {
            throw UsageServiceError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            throw UsageServiceError.usageFetchFailed(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    private func fetchAccountInfo(token: String, generation: Int) async {
        var request = URLRequest(url: URL(string: accountUrl)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              generation == sessionGeneration else { return }

        let email = json["email_address"] as? String
        var tier: String?
        var ravenType: String?
        if let memberships = json["memberships"] as? [[String: Any]] {
            // An account can belong to several orgs (e.g. free personal + paid team). Pick the
            // highest-tier one so the badge reflects the plan actually used, not just the first org.
            let orgs = memberships.compactMap { $0["organization"] as? [String: Any] }
            for org in orgs {
                Log.info("Org membership: name=\(org["name"] ?? "?"), rate_limit_tier=\(org["rate_limit_tier"] ?? "nil"), raven_type=\(org["raven_type"] ?? "nil"), billing_type=\(org["billing_type"] ?? "nil"), capabilities=\(org["capabilities"] ?? "nil")")
            }
            // Prefer the org this token was issued for; usage is per org, so the badge must match it.
            let tokenOrg = (try? TokenStore.load(profile: profile))?.organizationUUID
            let matching = tokenOrg.flatMap { uuid in orgs.first { ($0["uuid"] as? String) == uuid } }
            if let best = matching ?? orgs.max(by: {
                AccountInfo.tierRank($0["rate_limit_tier"] as? String) < AccountInfo.tierRank($1["rate_limit_tier"] as? String)
            }) {
                tier = best["rate_limit_tier"] as? String
                ravenType = best["raven_type"] as? String
            }
        }

        self.email = email
        self.accountInfo = AccountInfo(email: email, rateLimitTier: tier, ravenType: ravenType, billingType: nil)
        Log.info("Account: \(email ?? "?"), plan: \(accountInfo?.planLabel ?? "?")")
    }
}

enum UsageServiceError: LocalizedError {
    case usageFetchFailed(Int)
    case unauthorized
    case tokenRefreshFailed

    var errorDescription: String? {
        switch self {
        case .usageFetchFailed(let code):
            return "Usage fetch failed (HTTP \(code))"
        case .unauthorized:
            return "Token expired"
        case .tokenRefreshFailed:
            return "Token refresh failed"
        }
    }
}
