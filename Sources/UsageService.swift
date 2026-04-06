import Foundation

@MainActor
final class UsageService: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var error: String?
    @Published var isLoading = false
    @Published var needsLogin = false
    @Published var usageDelta: Double = 0 // change per poll

    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let tokenUrl = "https://platform.claude.com/v1/oauth/token"
    private let usageUrl = "https://api.anthropic.com/api/oauth/usage"
    private let userAgent = "claude-code/2.0.32"
    private let scopes = "user:profile user:inference"

    private var cachedAccessToken: String?
    private var tokenExpiresAt: Date?
    private var pollingTimer: Timer?
    private var resetTimer: Timer?

    let oauthService = OAuthService()

    private func loadCachedUsage() {
        guard let data = UserDefaults.standard.data(forKey: "cachedUsage"),
              let cached = try? JSONDecoder().decode(UsageResponse.self, from: data) else { return }
        self.usage = cached
    }

    private func cacheUsage(_ usage: UsageResponse) {
        if let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: "cachedUsage")
        }
    }

    func startPolling() {
        guard pollingTimer == nil else { return }
        loadCachedUsage()
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
        TokenStore.clear()
        cachedAccessToken = nil
        tokenExpiresAt = nil
        resetTimer?.invalidate()
        resetTimer = nil
        usage = nil
        error = nil
        needsLogin = true
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
            expiresAt: Int64((Date().timeIntervalSince1970 + Double(pair.expiresIn)) * 1000)
        )
        do {
            try TokenStore.save(tokens)
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

        do {
            let token = try await getValidAccessToken()
            let usageData = try await requestUsage(token: token)
            let previousUtilization = self.usage?.fiveHour.utilization ?? usageData.fiveHour.utilization
            self.usageDelta = max(0, usageData.fiveHour.utilization - previousUtilization)
            self.usage = usageData
            self.error = nil
            self.needsLogin = false
            cacheUsage(usageData)
            scheduleResetFetch(usageData)
            Log.info("Usage fetched: 5h=\(usageData.fiveHour.utilization)%, 7d=\(usageData.sevenDay.utilization)%")
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
                self.usage = usageData
                self.error = nil
                cacheUsage(usageData)
                scheduleResetFetch(usageData)
                Log.info("Refresh succeeded, usage: 5h=\(usageData.fiveHour.utilization)%")
            } catch {
                self.needsLogin = true
                self.error = "Session expired. Please login again."
                TokenStore.clear()
                Log.error("Refresh failed: \(error.localizedDescription)")
            }
        } catch UsageServiceError.usageFetchFailed(429) {
            if self.usage == nil {
                self.error = "Rate limited. Will retry shortly."
            }
            Log.info("Rate limited (429), keeping previous data")
        } catch UsageServiceError.tokenRefreshFailed {
            self.needsLogin = true
            self.usage = nil
            TokenStore.clear()
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

        let stored = try TokenStore.load()
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
        let stored = try TokenStore.load()
        guard let refreshToken = stored.refreshToken, !refreshToken.isEmpty else {
            throw TokenStoreError.noToken
        }
        return try await refreshAccessToken(refreshToken: refreshToken)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
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
        let newTokens = StoredTokens(
            accessToken: refreshResp.access_token,
            refreshToken: refreshResp.refresh_token ?? refreshToken,
            expiresAt: Int64((Date().timeIntervalSince1970 + Double(refreshResp.expires_in)) * 1000)
        )
        try TokenStore.save(newTokens)

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
