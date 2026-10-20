import Foundation

// messages api over raw http + sse. there's no official swift sdk.
// content blocks stay as plain json dicts so thinking/tool_use go back to the api untouched.
@MainActor
struct Claude {
    var model: String
    var auth: ClaudeAuth
    var session: URLSession
    private let usesOAuth: Bool

    init(model: String, auth: ClaudeAuth? = nil, session: URLSession = .shared) {
        let auth = auth ?? .shared
        self.model = model
        self.auth = auth
        self.session = session
        // A run must not switch billing methods when the user signs out mid-request.
        usesOAuth = auth.isSignedIn
    }

    enum Event {
        case text(String)
        case thinking
        case tool(String)
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    // flips if the api says this model doesn't take fallbacks
    @MainActor static var noFallbacks: Set<String> = []

    @MainActor
    func send(
        system: String,
        tools: [[String: Any]],
        messages: [[String: Any]],
        on: @MainActor (Event) -> Void
    ) async throws -> (content: [[String: Any]], stop: String) {
        let fallbacks = !Self.noFallbacks.contains(model)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 32000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "system": [["type": "text", "text": system]],
            "tools": tools,
            "messages": messages,
            // caches everything up to the last block, saves a lot on long runs
            "cache_control": ["type": "ephemeral"],
        ]
        if fallbacks { body["fallbacks"] = "default" }

        // env override is only for testing against a local fake
        let base = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"
        var req = URLRequest(url: URL(string: base + "/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        var refreshed = false
        var rejectedToken: String?
        while true {
            try Task.checkCancellation()
            let credential = try await auth.credential(rejectedToken: rejectedToken, useOAuth: usesOAuth)
            rejectedToken = nil
            credential.apply(to: &req, fallbacks: fallbacks)
            let (bytes, resp) = try await session.bytes(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return try await read(bytes, on: on) }

            var data = Data()
            for try await b in bytes { data.append(b) }
            let msg = Self.errorMessage(data) ?? "http \(status)"

            if status == 401, case .oauth(let token) = credential, !refreshed {
                refreshed = true
                rejectedToken = token
                continue
            }

            if status == 400, fallbacks, msg.lowercased().contains("fallback") {
                Self.noFallbacks.insert(model)
                return try await send(system: system, tools: tools, messages: messages, on: on)
            }
            // rate limit / overloaded: back off a few times
            if [429, 500, 502, 503, 529].contains(status), attempt < 4 {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(1 << attempt)))
                continue
            }
            if case .oauth = credential {
                if status == 429 {
                    let detail = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = ["", "error", "http 429"].contains(detail.lowercased()) ? "" : " \(detail)"
                    throw Failure(message: "claude rate-limited this account (http 429). try again later.\(suffix)")
                }
                if status == 401 {
                    throw Failure(message: "claude rejected this session. sign out and sign in again in settings.")
                }
                if status == 403 || msg.localizedCaseInsensitiveContains("only authorized") {
                    throw Failure(message: "claude denied subscription access for this app. \(msg)")
                }
            }
            throw Failure(message: status == 401 ? "The API key was rejected. Check it in Settings." : msg)
        }
    }

    @MainActor
    private func read(_ bytes: URLSession.AsyncBytes, on: @MainActor (Event) -> Void) async throws
        -> (content: [[String: Any]], stop: String)
    {
        var blocks: [[String: Any]] = []
        var json: [Int: String] = [:]
        var stop = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let raw = Data(line.dropFirst(5).utf8)
            guard let ev = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            let i = ev["index"] as? Int ?? 0

            switch ev["type"] as? String {
            case "content_block_start":
                let b = ev["content_block"] as? [String: Any] ?? [:]
                while blocks.count <= i { blocks.append([:]) }
                blocks[i] = b
                switch b["type"] as? String {
                case "tool_use": on(.tool(b["name"] as? String ?? ""))
                case "thinking", "redacted_thinking": on(.thinking)
                default: break
                }
            case "content_block_delta":
                guard i < blocks.count, let d = ev["delta"] as? [String: Any] else { continue }
                switch d["type"] as? String {
                case "text_delta":
                    let t = d["text"] as? String ?? ""
                    blocks[i]["text"] = (blocks[i]["text"] as? String ?? "") + t
                    on(.text(t))
                case "input_json_delta":
                    json[i, default: ""] += d["partial_json"] as? String ?? ""
                case "thinking_delta":
                    blocks[i]["thinking"] = (blocks[i]["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
                case "signature_delta":
                    blocks[i]["signature"] = (blocks[i]["signature"] as? String ?? "") + (d["signature"] as? String ?? "")
                default:
                    break
                }
            case "content_block_stop":
                if let s = json[i], !s.isEmpty, i < blocks.count {
                    blocks[i]["input"] = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) ?? [String: Any]()
                }
            case "message_delta":
                if let d = ev["delta"] as? [String: Any], let s = d["stop_reason"] as? String { stop = s }
            case "error":
                let e = ev["error"] as? [String: Any]
                throw Failure(message: e?["message"] as? String ?? "stream error")
            default:
                break
            }
        }
        return (blocks.filter { !$0.isEmpty }, stop)
    }

    static func errorMessage(_ data: Data) -> String? {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (obj?["error"] as? [String: Any])?["message"] as? String
    }
}
