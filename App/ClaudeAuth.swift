import CryptoKit
import Foundation
import Observation
import Security

enum ClaudeCredential {
    case apiKey(String)
    case oauth(String)

    func apply(to request: inout URLRequest, fallbacks: Bool) {
        request.setValue(nil, forHTTPHeaderField: "x-api-key")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        var betas = fallbacks ? ["server-side-fallback-2026-07-01"] : []
        switch self {
        case .apiKey(let key): request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .oauth(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            betas.append("oauth-2025-04-20")
        }
        request.setValue(betas.isEmpty ? nil : betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
    }
}

@Observable @MainActor
final class ClaudeAuth {
    static let shared = ClaudeAuth()

    // Compatibility with Claude's public CLI OAuth client, not a third-party registration.
    nonisolated static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    nonisolated static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    nonisolated static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let tokenKey = "claude.oauth.tokens"
    private static let flowKey = "claude.oauth.pending"

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    struct Login: Codable {
        var verifier: String
        var state: String
        var created: Date

        var url: URL {
            var url = URLComponents(string: "https://claude.ai/oauth/authorize")!
            url.queryItems = [
                URLQueryItem(name: "code", value: "true"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: ClaudeAuth.clientID),
                URLQueryItem(name: "redirect_uri", value: ClaudeAuth.redirectURI),
                URLQueryItem(name: "scope", value: "user:profile user:inference"),
                URLQueryItem(name: "code_challenge", value: Self.challenge(verifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
            ]
            return url.url!
        }

        static func challenge(_ verifier: String) -> String {
            Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        }

        func code(from input: String) throws -> String {
            let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let code: String?
            let returnedState: String?
            if let url = URLComponents(string: input), url.scheme != nil {
                guard url.scheme == "https", url.host == "platform.claude.com",
                      url.path == "/oauth/code/callback", url.user == nil, url.password == nil,
                      url.port == nil else {
                    throw Failure(message: "paste the code or callback URL shown by claude.")
                }
                let codes = url.queryItems?.filter { $0.name == "code" } ?? []
                let states = url.queryItems?.filter { $0.name == "state" } ?? []
                code = codes.count == 1 ? codes[0].value : nil
                returnedState = states.count == 1 ? states[0].value : nil
            } else {
                let parts = input.split(separator: "#", omittingEmptySubsequences: false)
                code = parts.count == 2 ? String(parts[0]) : nil
                returnedState = parts.count == 2 ? String(parts[1]) : nil
            }
            guard let code, !code.isEmpty, returnedState == state else {
                throw Failure(message: "that code doesn't match this sign-in. paste the full code, including the part after #, or start again.")
            }
            return code
        }
    }

    private var tokens: Tokens?
    private var login: Login?
    private(set) var isExchanging = false
    private let session: URLSession
    private let read: (String) -> String?
    private let write: (String, String) throws -> Void
    private var generation = 0
    private var refreshTask: Task<Tokens, Error>?

    init(session: URLSession = .shared,
         read: @escaping (String) -> String? = Keychain.get,
         write: @escaping (String, String) throws -> Void = Keychain.set) {
        self.session = session
        self.read = read
        self.write = write
        tokens = read(Self.tokenKey).flatMap { try? JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) }
        login = read(Self.flowKey).flatMap { try? JSONDecoder().decode(Login.self, from: Data($0.utf8)) }
    }

    var isSignedIn: Bool { tokens != nil }
    var pendingLogin: Bool { login != nil }
    var authorizationURL: URL? { login?.url }

    func beginSignIn() throws -> URL {
        guard !isExchanging else { throw Failure(message: "sign-in is already running.") }
        let login = Login(verifier: try Self.random(), state: try Self.random(), created: Date())
        try save(login, key: Self.flowKey)
        generation += 1
        self.login = login
        return login.url
    }

    func finishSignIn(_ input: String) async throws {
        guard !isExchanging else { return }
        guard let login, Date().timeIntervalSince(login.created) < 600 else {
            throw Failure(message: "this sign-in expired. cancel it and start again.")
        }
        let code = try login.code(from: input)
        let attempt = generation
        isExchanging = true
        defer { isExchanging = false }
        let tokens = try await requestTokens([
            "grant_type": "authorization_code", "code": code, "state": login.state,
            "client_id": Self.clientID, "redirect_uri": Self.redirectURI, "code_verifier": login.verifier,
        ])
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        try save(tokens, key: Self.tokenKey)
        self.tokens = tokens
        try write(Self.flowKey, "")
        self.login = nil
    }

    func cancelSignIn() throws {
        try write(Self.flowKey, "")
        generation += 1
        login = nil
    }

    func signOut() throws {
        // A late refresh must never recreate credentials after the user signs out.
        try write(Self.tokenKey, "")
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        try cancelSignIn()
    }

    func credential(rejectedToken: String? = nil, useOAuth: Bool? = nil) async throws -> ClaudeCredential {
        if useOAuth ?? isSignedIn {
            guard let tokens else {
                throw Failure(message: "claude was signed out. sign in again or start a new message.")
            }
            if tokens.expires.timeIntervalSinceNow > 60, rejectedToken != tokens.access {
                return .oauth(tokens.access)
            }
            if let task = refreshTask {
                let attempt = generation
                let updated = try await task.value
                try Task.checkCancellation()
                guard generation == attempt else { throw CancellationError() }
                return .oauth(updated.access)
            }
            let attempt = generation
            let task = Task { @MainActor in
                let updated = try await self.requestTokens([
                    "grant_type": "refresh_token", "refresh_token": tokens.refresh, "client_id": Self.clientID,
                ], previousRefresh: tokens.refresh)
                try Task.checkCancellation()
                guard self.generation == attempt else { throw CancellationError() }
                try self.save(updated, key: Self.tokenKey)
                self.tokens = updated
                return updated
            }
            refreshTask = task
            defer { if generation == attempt { refreshTask = nil } }
            let updated = try await task.value
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            return .oauth(updated.access)
        }
        let key = (read("anthropic") ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw Failure(message: "sign in to claude or add an anthropic api key in settings.")
        }
        return .apiKey(key)
    }

    private func requestTokens(_ body: [String: String], previousRefresh: String? = nil) async throws -> Tokens {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Never echo a token endpoint body: it may contain credentials or the submitted code.
            if [400, 401, 403].contains(status) {
                let action = previousRefresh == nil ? "cancel and sign in again" : "sign out and sign in again in settings"
                throw Failure(message: "claude rejected the login (http \(status)). \(action).")
            }
            throw Failure(message: "couldn't reach claude sign-in (http \(status)). try again.")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let access = json?["access_token"] as? String, !access.isEmpty,
              let refresh = (json?["refresh_token"] as? String) ?? previousRefresh, !refresh.isEmpty,
              let seconds = json?["expires_in"] as? Double, seconds.isFinite, seconds > 0 else {
            throw Failure(message: "claude returned incomplete login details. start sign-in again.")
        }
        return Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(seconds))
    }

    private func save<T: Encodable>(_ value: T, key: String) throws {
        try write(key, String(decoding: JSONEncoder().encode(value), as: UTF8.self))
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure(message: "couldn't start a secure sign-in. try again.")
        }
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
