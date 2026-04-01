import Foundation
import AppKit
import CryptoKit

@MainActor
final class OAuthService: ObservableObject {
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let authorizeUrl = "https://claude.ai/oauth/authorize"
    private let tokenUrl = "https://platform.claude.com/v1/oauth/token"
    private let redirectPath = "/callback"
    private let scopes = "user:profile user:inference"

    private var codeVerifier: String?
    private var oauthState: String?
    private var httpListener: HTTPListener?

    func startLogin(completion: @escaping (Result<TokenPair, Error>) -> Void) {
        let verifier = generateCodeVerifier()
        self.codeVerifier = verifier
        let challenge = generateCodeChallenge(verifier: verifier)

        let listener = HTTPListener(path: redirectPath) { [weak self] code in
            guard let self = self else { return }
            Task { @MainActor in
                do {
                    let tokens = try await self.exchangeCode(code)
                    completion(.success(tokens))
                } catch {
                    completion(.failure(error))
                }
                self.httpListener?.stop()
                self.httpListener = nil
            }
        }

        guard let port = listener.start() else {
            completion(.failure(OAuthError.listenerFailed))
            return
        }
        self.httpListener = listener

        let redirectUri = "http://localhost:\(port)\(redirectPath)"
        let state = generateCodeVerifier()
        self.oauthState = state
        var components = URLComponents(string: authorizeUrl)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func exchangeCode(_ code: String) async throws -> TokenPair {
        guard let verifier = codeVerifier else {
            throw OAuthError.noCodeVerifier
        }
        guard let listenerPort = httpListener?.port else {
            throw OAuthError.noRedirectUri
        }

        let redirectUri = "http://localhost:\(listenerPort)\(redirectPath)"

        var request = URLRequest(url: URL(string: tokenUrl)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientId,
            "code_verifier": verifier,
            "redirect_uri": redirectUri,
        ]
        if let state = oauthState {
            body["state"] = state
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed("No response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw OAuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        var email: String?
        if let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let account = rawJson["account"] as? [String: Any] {
            email = account["email_address"] as? String
        }

        struct TokenResponse: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }

        let tokenResp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TokenPair(
            accessToken: tokenResp.access_token,
            refreshToken: tokenResp.refresh_token,
            expiresIn: tokenResp.expires_in ?? 3600,
            email: email
        )
    }

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }
}

struct TokenPair {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let email: String?
}

enum OAuthError: LocalizedError {
    case noCodeVerifier
    case noRedirectUri
    case listenerFailed
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCodeVerifier: return "Missing code verifier"
        case .noRedirectUri: return "Missing redirect URI"
        case .listenerFailed: return "Failed to start local server"
        case .tokenExchangeFailed(let detail): return "Token exchange failed: \(detail)"
        }
    }
}

// MARK: - Base64URL encoding

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Minimal HTTP Listener for OAuth callback (IPv4 + IPv6)

final class HTTPListener: @unchecked Sendable {
    let path: String
    private let onCode: (String) -> Void
    private var socket4FD: Int32 = -1
    private var socket6FD: Int32 = -1
    private var listenThread: Thread?
    private(set) var port: UInt16 = 0

    init(path: String, onCode: @escaping (String) -> Void) {
        self.path = path
        self.onCode = onCode
    }

    func start() -> UInt16? {
        // Try IPv6 first (handles both IPv4 and IPv6 on macOS with IPV6_V6ONLY=0)
        socket6FD = socket(AF_INET6, SOCK_STREAM, 0)
        guard socket6FD >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(socket6FD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        // Allow both IPv4 and IPv6 connections
        var no: Int32 = 0
        setsockopt(socket6FD, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout.size(ofValue: no)))

        var addr6 = sockaddr_in6()
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = 0
        addr6.sin6_addr = in6addr_loopback

        let bindResult = withUnsafePointer(to: &addr6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket6FD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else { Darwin.close(socket6FD); return nil }

        var assignedAddr = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &assignedAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket6FD, $0, &len)
            }
        }
        self.port = UInt16(bigEndian: assignedAddr.sin6_port)

        listen(socket6FD, 5)

        listenThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        listenThread?.start()

        return port
    }

    func stop() {
        if socket6FD >= 0 { Darwin.close(socket6FD); socket6FD = -1 }
    }

    private func acceptLoop() {
        while socket6FD >= 0 {
            let clientFD = accept(socket6FD, nil, nil)
            guard clientFD >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(clientFD, &buffer, buffer.count)
            guard bytesRead > 0 else { Darwin.close(clientFD); continue }

            let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

            if let codeLine = requestStr.split(separator: "\r\n").first,
               codeLine.contains(path),
               let urlPart = codeLine.split(separator: " ").dropFirst().first,
               let components = URLComponents(string: String(urlPart)),
               let code = components.queryItems?.first(where: { $0.name == "code" })?.value {

                let html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body style=\"font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a2e;color:#fff\"><div style=\"text-align:center\"><h2>Authenticated!</h2><p>You can close this tab.</p></div></body></html>"
                _ = html.withCString { write(clientFD, $0, strlen($0)) }
                Darwin.close(clientFD)
                onCode(code)
                return
            } else {
                let resp = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nWaiting for auth..."
                _ = resp.withCString { write(clientFD, $0, strlen($0)) }
                Darwin.close(clientFD)
            }
        }
    }
}
