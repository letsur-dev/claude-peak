import Foundation

struct StoredTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Int64 // milliseconds since epoch
}

enum TokenStore {
    private static let tokenDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/claude-peak")

    private static func tokenFile(profile: String = "default") -> URL {
        let name = profile == "default" ? "tokens.json" : "tokens-\(profile).json"
        return tokenDir.appendingPathComponent(name)
    }

    static func load(profile: String = "default") throws -> StoredTokens {
        let file = tokenFile(profile: profile)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw TokenStoreError.noToken
        }
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode(StoredTokens.self, from: data)
    }

    static func save(_ tokens: StoredTokens, profile: String = "default") throws {
        try FileManager.default.createDirectory(at: tokenDir, withIntermediateDirectories: true)
        let file = tokenFile(profile: profile)
        let data = try JSONEncoder().encode(tokens)
        try data.write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func clear(profile: String = "default") {
        try? FileManager.default.removeItem(at: tokenFile(profile: profile))
    }
}

enum TokenStoreError: LocalizedError {
    case noToken

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No token configured"
        }
    }
}
