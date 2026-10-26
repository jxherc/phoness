import Foundation

final class Stub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var queue: [(Int, [String: String], Data)] = []
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    static func configure(_ responses: [(Int, [String: String], Data)]) {
        lock.lock(); defer { lock.unlock() }
        recorded = []; queue = responses
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let (status, headers, data) = Self.queue.isEmpty ? (500, [:], Data()) : Self.queue.removeFirst()
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct OpenAITests {
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: message, code: 1) }
    }

    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func sse(_ chunks: [Any]) -> Data {
        let lines = chunks.map { c -> String in
            if let s = c as? String { return "data: \(s)" }
            return "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: c), as: UTF8.self)
        }
        return Data((lines.joined(separator: "\n\n") + "\n\n").utf8)
    }

    @MainActor static func client(_ id: String, key: String = "test-key", url: String? = nil) -> OpenAI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let p = Providers.find(id)
        return OpenAI(provider: p, model: p.models.first?.id ?? "local", key: key, url: url ?? p.url, session: URLSession(configuration: config))
    }

    @MainActor static func main() async throws {
        let openai = Providers.find("openai"), deepseek = Providers.find("deepseek")
        let google = Providers.find("google"), mistral = Providers.find("mistral")

        // a claude turn with thinking, a tool call and its screenshot result
        let shot: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "AAAA"]]
        let history: [[String: Any]] = [
            ["role": "user", "content": "open settings"],
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "hmm", "signature": "sig"],
                ["type": "text", "text": "Looking."],
                ["type": "tool_use", "id": "toolu_01", "name": "phone_act", "input": ["action": "tap", "x": 10, "y": 20]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_01", "content": [["type": "text", "text": "Done."], shot]],
            ]],
        ]
        let msgs = OpenAI.messages("sys", history, openai)
        try check(msgs.count == 5, "system, user, assistant, tool, image message")
        try check(msgs[0]["role"] as? String == "system" && msgs[0]["content"] as? String == "sys", "system first")
        try check(msgs[1]["content"] as? String == "open settings", "plain user text")
        let a = msgs[2]
        let call = (a["tool_calls"] as? [[String: Any]])?.first
        let fn = call?["function"] as? [String: Any]
        let args = (fn?["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        try check(a["content"] as? String == "Looking." && call?["id"] as? String == "toolu_01" && fn?["name"] as? String == "phone_act"
            && args?["action"] as? String == "tap" && (args?["x"] as? Int) == 10, "assistant text and tool call")
        try check(a["reasoning_content"] == nil && a["thinking"] == nil, "claude thinking stays behind")
        try check(msgs[3]["role"] as? String == "tool" && msgs[3]["tool_call_id"] as? String == "toolu_01" && msgs[3]["content"] as? String == "Done.", "tool result text")
        let img = msgs[4]["content"] as? [[String: Any]]
        try check(msgs[4]["role"] as? String == "user" && (img?[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,AAAA", "screenshot follows as a user image")

        // a tool result that's only an image still says something
        let onlyImage = OpenAI.messages("s", [["role": "user", "content": [["type": "tool_result", "tool_use_id": "x", "content": [shot]]]]], openai)
        try check(onlyImage[1]["content"] as? String == "(see attached image)", "image-only tool result placeholder")

        // reasoning and gemini signatures only go back to the provider that made them
        let own: [[String: Any]] = [["role": "assistant", "content": [
            ["type": "reasoning", "via": "deepseek", "field": "reasoning_content", "text": "think"],
            ["type": "tool_use", "id": "c1", "name": "phone_look", "input": [String: Any](), "via": "google", "extra_content": ["google": ["thought_signature": "s1"]]],
        ]]]
        let toDeepseek = OpenAI.messages("s", own, deepseek)[1]
        try check(toDeepseek["reasoning_content"] as? String == "think", "deepseek reasoning replayed")
        try check((toDeepseek["tool_calls"] as? [[String: Any]])?.first?["extra_content"] == nil, "gemini signature not sent to deepseek")
        let toGoogle = OpenAI.messages("s", own, google)[1]
        try check(toGoogle["reasoning_content"] == nil, "deepseek reasoning not sent to gemini")
        let extra = (toGoogle["tool_calls"] as? [[String: Any]])?.first?["extra_content"] as? [String: Any]
        try check((extra?["google"] as? [String: Any])?["thought_signature"] as? String == "s1", "gemini signature replayed")
        try check(toGoogle["content"] is NSNull, "tool-only assistant message has null content")
        let claudeToDeepseek = OpenAI.messages("s", Array(history[1...1]), deepseek)[1]
        try check(claudeToDeepseek["reasoning_content"] as? String == "", "deepseek gets empty reasoning_content on other turns")

        // mistral ids: 9 letters or digits, same on the call and the result
        let mixed = OpenAI.messages("s", history, mistral)
        let mid = ((mixed[2]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
        try check(mid.count == 9 && mid.allSatisfy { $0.isLetter || $0.isNumber } && mixed[3]["tool_call_id"] as? String == mid, "mistral id mapping")
        try check(OpenAI.id("abcDEF123", mistral) == "abcDEF123", "mistral keeps its own ids")

        // gemini refuses tools with no properties
        let defs: [[String: Any]] = [
            ["name": "look", "description": "d", "input_schema": ["type": "object", "properties": [String: Any]()]],
            ["name": "act", "description": "d", "input_schema": ["type": "object", "properties": ["x": ["type": "number"]]]],
        ]
        let gt = OpenAI.tools(defs, google).map { $0["function"] as? [String: Any] ?? [:] }
        let ot = OpenAI.tools(defs, openai).map { $0["function"] as? [String: Any] ?? [:] }
        try check(gt[0]["parameters"] == nil && gt[1]["parameters"] != nil && ot[0]["parameters"] != nil, "bare tools only for gemini")

        // anthropic gets a clean history back
        let cleaned = Claude.clean([
            ["role": "assistant", "content": [
                ["type": "reasoning", "via": "moonshot", "text": "t"],
                ["type": "text", "text": "ok"],
                ["type": "tool_use", "id": "functions.phone_act:0", "name": "phone_act", "input": [String: Any](), "via": "google", "extra_content": ["a": 1]],
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "functions.phone_act:0", "content": "x"]]],
        ])
        let cb = cleaned[0]["content"] as? [[String: Any]] ?? []
        try check(cb.count == 2 && cb[1]["via"] == nil && cb[1]["extra_content"] == nil && cb[1]["id"] as? String == "functions_phone_act_0", "clean assistant turn")
        try check((cleaned[1]["content"] as? [[String: Any]])?.first?["tool_use_id"] as? String == "functions_phone_act_0", "clean tool result id")

        // streaming: reasoning, text, a tool call split over chunks, then finish
        Stub.configure([(200, [:], sse([
            ["choices": [["index": 0, "delta": ["role": "assistant", "reasoning_content": "plan "]]]],
            ["choices": [["index": 0, "delta": ["reasoning_content": "it"]]]],
            ["choices": [["index": 0, "delta": ["content": "Tapping."]]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "id": "call_1", "type": "function", "function": ["name": "phone_act", "arguments": "{\"action\":"]]]]]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "function": ["arguments": "\"tap\",\"x\":5}"]]]]]]],
            ["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "tool_calls"]]],
            "[DONE]",
        ]))])
        var events: [String] = []
        let ds = client("deepseek")
        let res = try await ds.send(system: "sys", tools: defs, messages: [["role": "user", "content": "hi"]]) { ev in
            switch ev {
            case .text(let t): events.append("text:\(t)")
            case .thinking: events.append("thinking")
            case .tool(let n): events.append("tool:\(n)")
            }
        }
        try check(res.stop == "tool_use", "tool_calls maps to tool_use")
        try check(res.content.count == 3, "reasoning, text, tool blocks")
        try check(res.content[0]["type"] as? String == "reasoning" && res.content[0]["text"] as? String == "plan it" && res.content[0]["field"] as? String == "reasoning_content" && res.content[0]["via"] as? String == "deepseek", "reasoning block")
        try check(res.content[1]["text"] as? String == "Tapping.", "text block")
        let input = res.content[2]["input"] as? [String: Any]
        try check(res.content[2]["id"] as? String == "call_1" && res.content[2]["name"] as? String == "phone_act" && input?["action"] as? String == "tap" && (input?["x"] as? Int) == 5, "tool block")
        try check(events == ["thinking", "thinking", "text:Tapping.", "tool:phone_act"], "events in order")
        let req = Stub.requests[0]
        let sent = body(req)
        try check(req.url?.absoluteString == "https://api.deepseek.com/chat/completions" && req.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "endpoint and bearer key")
        try check(sent["model"] as? String == "deepseek-flash" && sent["stream"] as? Bool == true && (sent["max_tokens"] as? Int) == 32000 && sent["max_completion_tokens"] == nil, "deepseek body")
        try check((sent["tools"] as? [[String: Any]])?.count == 2, "tools sent")

        // finish "stop" with a call is still a tool turn; a gemini signature is kept; no id gets one
        Stub.configure([(200, [:], sse([
            ["choices": [["index": 0, "delta": ["tool_calls": [["function": ["name": "phone_look", "arguments": "{}"], "extra_content": ["google": ["thought_signature": "sig"]]]]]]]],
            ["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "stop"]]],
        ]))])
        let g = try await client("google").send(system: "s", tools: [], messages: []) { _ in }
        try check(g.stop == "tool_use" && (g.content[0]["id"] as? String ?? "").hasPrefix("call_") && g.content[0]["via"] as? String == "google" && g.content[0]["extra_content"] != nil, "gemini call without id")
        let gb = body(Stub.requests[0])
        try check(gb["max_tokens"] == nil && gb["max_completion_tokens"] == nil, "no token field unless the provider needs one")

        // a stream that ends without finish_reason isn't safe to keep
        Stub.configure([(200, [:], sse([["choices": [["index": 0, "delta": ["content": "hal"]]]]]))])
        let cut = try await client("openai").send(system: "s", tools: [], messages: []) { _ in }
        try check(cut.stop == "", "missing finish_reason")

        // openrouter reasoning_details pieces join up
        Stub.configure([(200, [:], sse([
            ["choices": [["index": 0, "delta": ["reasoning_details": [["type": "reasoning.text", "text": "a", "index": 0]]]]]],
            ["choices": [["index": 0, "delta": ["reasoning_details": [["type": "reasoning.text", "text": "b", "signature": "sg"]]]]]],
            ["choices": [["index": 0, "delta": ["reasoning_details": [["type": "reasoning.encrypted", "data": "enc"]], "content": "hi"], "finish_reason": "stop"]]],
        ]))])
        let or = try await client("openrouter").send(system: "s", tools: [], messages: []) { _ in }
        let details = or.content[0]["details"] as? [[String: Any]] ?? []
        try check(or.stop == "end_turn" && details.count == 2 && details[0]["text"] as? String == "ab" && details[0]["signature"] as? String == "sg" && details[1]["data"] as? String == "enc", "reasoning_details merge")
        let back = OpenAI.messages("s", [["role": "assistant", "content": or.content]], Providers.find("openrouter"))[1]
        try check((back["reasoning_details"] as? [[String: Any]])?.count == 2 && back["content"] as? String == "hi", "reasoning_details replay")

        // errors: retry on 429, then key and provider messages
        Stub.configure([
            (429, ["retry-after": "0"], Data(#"{"error":{"message":"slow down"}}"#.utf8)),
            (200, [:], sse([["choices": [["index": 0, "delta": ["content": "ok"], "finish_reason": "stop"]]]])),
        ])
        let retried = try await client("openai").send(system: "s", tools: [], messages: []) { _ in }
        try check(retried.stop == "end_turn" && Stub.requests.count == 2, "429 retried")

        func failure(_ c: OpenAI, _ responses: [(Int, [String: String], Data)]) async -> String {
            Stub.configure(responses)
            do { _ = try await c.send(system: "s", tools: [], messages: []) { _ in }; return "" } catch { return error.localizedDescription }
        }
        let bad = await failure(client("xai"), [(401, [:], Data(#"{"error":"Incorrect API key"}"#.utf8))])
        try check(bad.contains("xAI rejected the API key") && bad.contains("Incorrect API key"), "401 names the provider and key")
        let gemini = await failure(client("google"), [(400, [:], Data(#"[{"error":{"code":400,"message":"Request contains an invalid argument.","status":"INVALID_ARGUMENT"}}]"#.utf8))])
        try check(gemini == "Google Gemini: Request contains an invalid argument.", "gemini array error")
        let midStream = await failure(client("groq"), [(200, [:], sse([["error": ["message": "model overloaded"]]]))])
        try check(midStream == "Groq: model overloaded", "error inside the stream")
        let noKey = await failure(client("openai", key: ""), [])
        try check(noKey == "Add your OpenAI API key in Settings." && Stub.requests.isEmpty, "missing key stops before any request")
        let noURL = await failure(client("custom", key: "", url: ""), [])
        try check(noURL.hasPrefix("Add the server's base URL") && Stub.requests.isEmpty, "custom needs a url")

        // custom: no key is fine, no auth header, trailing slash handled
        Stub.configure([(200, [:], sse([["choices": [["index": 0, "delta": ["content": "x"], "finish_reason": "stop"]]]]))])
        _ = try await client("custom", key: "", url: "http://127.0.0.1:8081/v1/").send(system: "s", tools: [], messages: []) { _ in }
        try check(Stub.requests[0].url?.absoluteString == "http://127.0.0.1:8081/v1/chat/completions" && Stub.requests[0].value(forHTTPHeaderField: "Authorization") == nil, "custom server without key")

        print("openai-compatible client checks passed")
    }
}
