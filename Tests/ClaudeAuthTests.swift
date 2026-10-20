import Foundation

final class Stub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }
    static var status = 200
    static var payload: [String: Any] = [:]
    static var delay = 0.0
    static var sequence: [(Int, Data)] = []
    static func configureSequence(_ responses: [(Int, Data)], delay: Double = 0) {
        lock.lock(); defer { lock.unlock() }
        recordedRequests = []; sequence = responses; self.delay = delay
    }
    static func configure(_ payload: [String: Any], status: Int = 200, delay: Double = 0) {
        lock.lock(); defer { lock.unlock() }
        recordedRequests = []; sequence = []; self.payload = payload; self.status = status; self.delay = delay
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let response = Self.sequence.isEmpty ? (Self.status, try! JSONSerialization.data(withJSONObject: Self.payload)) : Self.sequence.removeFirst()
        let (status, data) = response
        let delay = Self.delay
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor final class Store {
    var values: [String: String] = [:]
    var fail = false
    func auth() -> ClaudeAuth {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return ClaudeAuth(session: URLSession(configuration: config), read: { self.values[$0] }, write: {
            if self.fail { throw NSError(domain: "test-storage", code: 1) }
            self.values[$0] = $1
        })
    }
    func seed(expired: Bool = true) throws {
        values["claude.oauth.tokens"] = String(decoding: try JSONEncoder().encode(ClaudeAuth.Tokens(access: "old", refresh: "original-refresh", expires: Date().addingTimeInterval(expired ? -1 : 3600))), as: UTF8.self)
    }
    func tokens() throws -> ClaudeAuth.Tokens { try JSONDecoder().decode(ClaudeAuth.Tokens.self, from: Data(values["claude.oauth.tokens"]!.utf8)) }
}

@main struct AuthTests {
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: message, code: 1) }
    }
    @MainActor static func rejected(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw NSError(domain: "expected rejection", code: 1)
    }
    @MainActor static func oauth(_ auth: ClaudeAuth) async throws -> String {
        switch try await auth.credential() {
        case .oauth(let token): return token
        case .apiKey: throw NSError(domain: "unexpected api-key fallback", code: 1)
        }
    }
    @MainActor static func main() async throws {
        try check(ClaudeAuth.Login.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC7636 challenge")
        let store = Store(), auth = store.auth()
        let url = try auth.beginSignIn()
        let params = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        let state = params["state"]!
        try check(params["client_id"] == ClaudeAuth.clientID && params["redirect_uri"] == ClaudeAuth.redirectURI && params["code_challenge_method"] == "S256" && params["response_type"] == "code" && params["scope"] == "user:profile user:inference", "authorization parameters")
        let another = Store().auth()
        let otherURL = try another.beginSignIn()
        try check(otherURL != url && state.count == 43, "random state")
        Stub.configure(["access_token": "new", "refresh_token": "refresh", "expires_in": 3600])
        for bad in ["code", "code#wrong", "https://platform.claude.com/oauth/code/callback?code=x", "https://platform.claude.com/oauth/code/callback?code=x&state=\(state)&state=\(state)", "https://evil.example/oauth/code/callback?code=x&state=\(state)"] {
            try await rejected { try await auth.finishSignIn(bad) }
        }
        try check(Stub.requests.isEmpty, "invalid callbacks must not reach token endpoint")
        let resumed = store.auth()
        try check(resumed.pendingLogin && resumed.authorizationURL == url, "pending login persistence")
        try await resumed.finishSignIn("code#\(state)")
        try check(resumed.isSignedIn && !resumed.pendingLogin && store.values["claude.oauth.pending"] == "", "exchange persistence")
        let request = Stub.requests[0]
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? readBody(request)) as! [String: String]
        try check(request.httpMethod == "POST" && body["code"] == "code" && body["state"] == state && body["grant_type"] == "authorization_code" && body["redirect_uri"] == ClaudeAuth.redirectURI && ClaudeAuth.Login.challenge(body["code_verifier"]!) == params["code_challenge"], "exchange body")
        try check(try store.tokens().access == "new", "saved access token")
        let expired = Store()
        expired.values["claude.oauth.pending"] = String(decoding: try JSONEncoder().encode(ClaudeAuth.Login(verifier: "verifier", state: "state", created: Date().addingTimeInterval(-601))), as: UTF8.self)
        Stub.configure([:])
        try await rejected { try await expired.auth().finishSignIn("code#state") }
        try check(Stub.requests.isEmpty, "expired login rejected locally")

        let refreshStore = Store(); try refreshStore.seed()
        let refreshAuth = refreshStore.auth()
        Stub.configure(["access_token": "rotated", "refresh_token": "rotated-refresh", "expires_in": 3600], delay: 0.1)
        async let a = oauth(refreshAuth)
        async let b = oauth(refreshAuth)
        let pair = try await (a, b)
        try check(pair.0 == "rotated" && pair.1 == "rotated" && Stub.requests.count == 1, "refresh coalescing")
        try check(try refreshStore.tokens().refresh == "rotated-refresh", "refresh rotation")
        try refreshStore.seed()
        Stub.configure(["access_token": "no-rotation", "expires_in": 3600])
        _ = try await oauth(refreshStore.auth())
        try check(try refreshStore.tokens().refresh == "original-refresh", "omitted refresh retained")
        try refreshStore.seed(); refreshStore.values["anthropic"] = "fallback-key"
        let failureAuth = refreshStore.auth()
        Stub.configure(["error": "synthetic-secret"], status: 401)
        try await rejected { _ = try await failureAuth.credential() }
        try check(try refreshStore.tokens().access == "old" && failureAuth.isSignedIn, "failure retains tokens")

        let signoutStore = Store(); try signoutStore.seed()
        let signoutAuth = signoutStore.auth()
        Stub.configure(["access_token": "late", "refresh_token": "late-refresh", "expires_in": 3600], delay: 0.2)
        let pending = Task { try await oauth(signoutAuth) }
        for _ in 0..<100 {
            if !Stub.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try check(Stub.requests.count == 1, "refresh in flight before signout")
        try signoutAuth.signOut()
        do { _ = try await pending.value; throw NSError(domain: "late refresh succeeded", code: 1) } catch is CancellationError {} catch let error as NSError where error.domain == NSURLErrorDomain {}
        try check(!signoutAuth.isSignedIn && signoutStore.values["claude.oauth.tokens"] == "", "signout survives late response")
        let failingStore = Store(); failingStore.fail = true
        try await rejected { _ = try failingStore.auth().beginSignIn() }
        try failingStore.seed()
        Stub.configure(["access_token": "unsaved", "refresh_token": "new-refresh", "expires_in": 3600])
        try await rejected { _ = try await oauth(failingStore.auth()) }
        try check(try failingStore.tokens().access == "old", "storage error does not replace persisted tokens")
        let exchangeStore = Store(), exchangeAuth = exchangeStore.auth()
        let exchangeURL = try exchangeAuth.beginSignIn()
        let exchangeState = URLComponents(url: exchangeURL, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        exchangeStore.fail = true
        try await rejected { try await exchangeAuth.finishSignIn("code#\(exchangeState)") }
        try check(!exchangeAuth.isSignedIn && exchangeAuth.pendingLogin, "exchange storage error surfaces without losing pending login")
        var headers = URLRequest(url: ClaudeAuth.tokenURL)
        ClaudeCredential.apiKey("key").apply(to: &headers, fallbacks: false)
        try check(headers.value(forHTTPHeaderField: "x-api-key") == "key" && headers.value(forHTTPHeaderField: "Authorization") == nil, "api key headers")
        ClaudeCredential.oauth("token").apply(to: &headers, fallbacks: true)
        try check(headers.value(forHTTPHeaderField: "x-api-key") == nil && headers.value(forHTTPHeaderField: "Authorization") == "Bearer token" && headers.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01,oauth-2025-04-20", "oauth headers and betas")
        ClaudeCredential.apiKey("key").apply(to: &headers, fallbacks: false)
        try check(headers.value(forHTTPHeaderField: "Authorization") == nil && headers.value(forHTTPHeaderField: "anthropic-beta") == nil, "header cleanup")
        try await messagesTests()
        print("auth and messages regressions passed")
    }
    @MainActor static func messagesTests() async throws {
        let sse = Data(([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            "", "",
        ].joined(separator: "\n")).utf8)
        func error(_ message: String) -> Data { try! JSONSerialization.data(withJSONObject: ["error": ["message": message]]) }
        let rotated = try JSONSerialization.data(withJSONObject: ["access_token": "rotated", "refresh_token": "rotated-refresh", "expires_in": 3600])
        func client(_ store: Store, model: String) -> Claude {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
            return Claude(model: model, auth: store.auth(), session: URLSession(configuration: config))
        }
        let store = Store(); try store.seed(expired: false); store.values["anthropic"] = "must-not-use"
        let claude = client(store, model: "retry-model")
        Stub.configureSequence([(401, error("expired")), (200, rotated), (200, sse)])
        var text = ""
        let response = try await claude.send(system: "test", tools: [], messages: []) { if case .text(let value) = $0 { text += value } }
        try check(response.stop == "end_turn" && response.content.first?["text"] as? String == "hello" && text == "hello", "SSE parsing after refresh")
        var requests = Stub.requests
        try check(requests.count == 3 && requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer old" && requests[1].url == ClaudeAuth.tokenURL && requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer rotated" && requests.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == nil }, "401 refresh and bearer replay")
        try store.seed(expired: false)
        Stub.configureSequence([(401, error("expired")), (200, rotated), (401, error("still rejected"))])
        try await rejected { _ = try await client(store, model: "twice-model").send(system: "test", tools: [], messages: []) { _ in } }
        try check(Stub.requests.count == 3, "repeated 401 refreshes only once")
        try store.seed(expired: false)
        Stub.configureSequence([(403, error("only authorized for Claude Code"))])
        do {
            _ = try await client(store, model: "restricted-model").send(system: "test", tools: [], messages: []) { _ in }
            throw NSError(domain: "403 unexpectedly succeeded", code: 1)
        } catch let failure as Claude.Failure {
            try check(failure.message.contains("denied subscription access") && failure.message.contains("only authorized"), "403 restriction explained")
        }
        try check(Stub.requests.count == 1 && Stub.requests[0].value(forHTTPHeaderField: "x-api-key") == nil, "403 never falls back to API key")
        Stub.configureSequence(Array(repeating: (429, error("Error")), count: 5))
        do {
            _ = try await client(store, model: "rate-limited-model").send(system: "test", tools: [], messages: []) { _ in }
            throw NSError(domain: "429 unexpectedly succeeded", code: 1)
        } catch let failure as Claude.Failure {
            try check(failure.message == "claude rejected the subscription request (http 429). this may be a usage limit or a restriction on this app.", "generic 429 explains uncertain subscription rejection")
        }
        try check(Stub.requests.count == 5 && Stub.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer old" && $0.value(forHTTPHeaderField: "x-api-key") == nil
        }, "429 exhausts retries using OAuth without API fallback")
        // A run stays tied to its starting billing method through retries and tool turns.
        for status in [401, 400] {
            let signingOutStore = Store(); try signingOutStore.seed(expired: false)
            signingOutStore.values["anthropic"] = "saved-api-key"
            let signingOutAuth = signingOutStore.auth()
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
            let originalRun = Claude(model: "signout-\(status)", auth: signingOutAuth, session: URLSession(configuration: config))
            Stub.configureSequence([(status, error(status == 400 ? "fallbacks unavailable" : "expired"))], delay: 0.15)
            let sending = Task { try await originalRun.send(system: "test", tools: [], messages: []) { _ in } }
            for _ in 0..<100 {
                if !Stub.requests.isEmpty { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try check(Stub.requests.count == 1, "message in flight before signout")
            try signingOutAuth.signOut()
            try await rejected { _ = try await sending.value }
            try check(Stub.requests.count == 1 && Stub.requests[0].value(forHTTPHeaderField: "x-api-key") == nil, "signout prevents retry billing switch")
            try await rejected { _ = try await originalRun.send(system: "next tool turn", tools: [], messages: []) { _ in } }
            try check(Stub.requests.count == 1, "original run cannot switch credentials on next tool turn")
            Stub.configureSequence([(200, sse)])
            let newRun = Claude(model: "new-run-\(status)", auth: signingOutAuth, session: URLSession(configuration: config))
            _ = try await newRun.send(system: "new run", tools: [], messages: []) { _ in }
            try check(Stub.requests.count == 1 && Stub.requests[0].value(forHTTPHeaderField: "x-api-key") == "saved-api-key" && Stub.requests[0].value(forHTTPHeaderField: "Authorization") == nil, "new run after signout can use saved API key")
        }
        let apiStore = Store(); apiStore.values["anthropic"] = "synthetic-key"
        Stub.configureSequence([(200, sse)])
        let apiResponse = try await client(apiStore, model: "api-model").send(system: "test", tools: [], messages: []) { _ in }
        try check(apiResponse.stop == "end_turn" && Stub.requests[0].value(forHTTPHeaderField: "x-api-key") == "synthetic-key" && Stub.requests[0].value(forHTTPHeaderField: "Authorization") == nil, "API key SSE regression")
        try store.seed(expired: false)
        Stub.configureSequence([(400, error("fallbacks unavailable")), (200, sse)])
        _ = try await client(store, model: "fallback-model").send(system: "test", tools: [], messages: []) { _ in }
        requests = Stub.requests
        let replayBody = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? readBody(requests[1])) as! [String: Any]
        try check(requests.count == 2 && requests[1].value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20" && replayBody["fallbacks"] == nil && requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer old", "fallback retry retains OAuth beta")
    }
    static func readBody(_ request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return data
    }
}
