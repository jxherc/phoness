import Foundation

// openai chat completions over raw http + sse, for every provider but anthropic.
// the history stays in anthropic's block format and gets translated both ways here.
// follows pi's openai-completions client: tool screenshots go in a user message after the
// tool results, reasoning goes back the way it came, provider quirks are flags on Provider
@MainActor
struct OpenAI: LLM {
    var provider: Provider
    var model: String
    var key: String
    var url: String
    var session: URLSession = .shared

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    func send(
        system: String,
        tools: [[String: Any]],
        messages: [[String: Any]],
        on: @MainActor (LLMEvent) -> Void
    ) async throws -> (content: [[String: Any]], stop: String) {
        guard !model.isEmpty else { throw Failure(message: "Pick a \(provider.name) model in Settings.") }
        let base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/chat/completions"),
              endpoint.scheme == "https" || endpoint.scheme == "http", endpoint.host != nil else {
            throw Failure(message: "Add the server's base URL in Settings, like https://example.com/v1.")
        }
        guard !key.isEmpty || provider.id == "custom" else {
            throw Failure(message: "Add your \(provider.name) API key in Settings.")
        }

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": Self.messages(system, messages, provider),
            "tools": Self.tools(tools, provider),
        ]
        if let field = provider.limit { body[field] = 32000 }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let bytes: URLSession.AsyncBytes
            let resp: URLResponse
            do {
                (bytes, resp) = try await session.bytes(for: req)
            } catch let e as URLError where Claude.flaky.contains(e.code) && attempt < 3 {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(1 << attempt)))
                continue
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return try await read(bytes, on: on) }

            var data = Data()
            for try await b in bytes { data.append(b) }
            if [429, 500, 502, 503, 529].contains(status), attempt < 4 {
                attempt += 1
                let asked = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                try await Task.sleep(for: .seconds(min(asked ?? Double(1 << attempt), 30)))
                continue
            }
            let msg = Self.errorMessage(data) ?? "http \(status)"
            if status == 401 || status == 403 {
                throw Failure(message: "\(provider.name) rejected the API key (http \(status)). Check it in Settings. \(msg)")
            }
            throw Failure(message: "\(provider.name): \(msg)")
        }
    }

    private struct Call {
        var id = ""
        var name = ""
        var args = ""
        var extra: Any?
    }

    private func read(_ bytes: URLSession.AsyncBytes, on: @MainActor (LLMEvent) -> Void) async throws
        -> (content: [[String: Any]], stop: String)
    {
        var text = ""
        var reasoning = ""
        var field = ""
        var details: [[String: Any]] = []
        var calls: [Call] = []
        var slot: [Int: Int] = [:]
        var finish: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if raw == "[DONE]" { break }
            guard let ev = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { continue }
            if let e = ev["error"] { throw Failure(message: "\(provider.name): \(Self.message(e) ?? "stream error")") }
            guard let choice = (ev["choices"] as? [[String: Any]])?.first else { continue }
            if let f = choice["finish_reason"] as? String { finish = f }
            guard let d = choice["delta"] as? [String: Any] else { continue }

            if let t = d["content"] as? String, !t.isEmpty {
                text += t
                on(.text(t))
            }
            // providers name this field differently. the first one wins, some send two copies
            if let f = ["reasoning_content", "reasoning", "reasoning_text"].first(where: { !(d[$0] as? String ?? "").isEmpty }) {
                if field.isEmpty { field = f }
                reasoning += d[f] as? String ?? ""
                on(.thinking)
            }
            // openrouter streams structured reasoning in pieces, text and summary pieces join up
            for detail in d["reasoning_details"] as? [[String: Any]] ?? [] {
                let type = detail["type"] as? String
                if let last = details.last, last["type"] as? String == type,
                   let k = type == "reasoning.text" ? "text" : type == "reasoning.summary" ? "summary" : nil {
                    details[details.count - 1][k] = (last[k] as? String ?? "") + (detail[k] as? String ?? "")
                    for f in ["id", "format", "index", "signature"] where details[details.count - 1][f] == nil {
                        details[details.count - 1][f] = detail[f]
                    }
                } else {
                    details.append(detail)
                }
                on(.thinking)
            }
            for tc in d["tool_calls"] as? [[String: Any]] ?? [] {
                let id = tc["id"] as? String ?? ""
                let i: Int
                if let index = tc["index"] as? Int, let s = slot[index] {
                    i = s
                } else if let index = tc["index"] as? Int {
                    i = calls.count
                    slot[index] = i
                    calls.append(Call())
                } else if let s = calls.firstIndex(where: { !id.isEmpty && $0.id == id }) ?? (id.isEmpty ? calls.indices.last : nil) {
                    i = s
                } else {
                    i = calls.count
                    calls.append(Call())
                }
                if calls[i].id.isEmpty { calls[i].id = id }
                let fn = tc["function"] as? [String: Any]
                if calls[i].name.isEmpty, let n = fn?["name"] as? String, !n.isEmpty {
                    calls[i].name = n
                    on(.tool(n))
                }
                if let a = fn?["arguments"] as? String {
                    calls[i].args += a
                } else if let a = fn?["arguments"] as? [String: Any], let s = try? JSONSerialization.data(withJSONObject: a) {
                    calls[i].args += String(decoding: s, as: UTF8.self)
                }
                // gemini's thought signature, it has to come back with the call
                if let x = tc["extra_content"] { calls[i].extra = x }
            }
        }

        var content: [[String: Any]] = []
        if !reasoning.isEmpty || !details.isEmpty {
            var r: [String: Any] = ["type": "reasoning", "via": provider.id, "text": reasoning]
            if !field.isEmpty { r["field"] = field }
            if !details.isEmpty { r["details"] = details }
            content.append(r)
        }
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        for c in calls where !c.name.isEmpty {
            let input = (try? JSONSerialization.jsonObject(with: Data(c.args.utf8))) as? [String: Any] ?? [:]
            var b: [String: Any] = [
                "type": "tool_use",
                "id": c.id.isEmpty ? "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24) : c.id,
                "name": c.name,
                "input": input,
            ]
            if let x = c.extra {
                b["extra_content"] = x
                b["via"] = provider.id
            }
            content.append(b)
        }

        guard let finish else { return (content, "") }
        let called = content.contains { $0["type"] as? String == "tool_use" }
        switch finish {
        case "length": return (content, "max_tokens")
        case "content_filter": return (content, "refusal")
        // some providers say stop even when they called a tool
        case _ where called: return (content, "tool_use")
        case "stop", "end", "tool_calls", "function_call": return (content, "end_turn")
        default: throw Failure(message: "\(provider.name) stopped the reply: \(finish)")
        }
    }

    // MARK: translation

    static func tools(_ defs: [[String: Any]], _ p: Provider) -> [[String: Any]] {
        defs.map { d in
            var fn: [String: Any] = ["name": d["name"] ?? "", "description": d["description"] ?? ""]
            let schema = d["input_schema"] as? [String: Any]
            if !(p.bareTools && (schema?["properties"] as? [String: Any])?.isEmpty ?? true) {
                fn["parameters"] = schema
            }
            return ["type": "function", "function": fn]
        }
    }

    static func messages(_ system: String, _ history: [[String: Any]], _ p: Provider) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for m in history {
            let role = m["role"] as? String ?? "user"
            guard let blocks = m["content"] as? [[String: Any]] else {
                if let s = m["content"] as? String, !s.isEmpty { out.append(["role": role, "content": s]) }
                continue
            }
            if role == "assistant" {
                if let a = assistant(blocks, p) { out.append(a) }
                continue
            }
            var images: [[String: Any]] = []
            var parts: [[String: Any]] = []
            for b in blocks {
                switch b["type"] as? String {
                case "tool_result":
                    var texts: [String] = []
                    var seen = false
                    if let s = b["content"] as? String { texts.append(s) }
                    for c in b["content"] as? [[String: Any]] ?? [] {
                        if c["type"] as? String == "text", let t = c["text"] as? String {
                            texts.append(t)
                        } else if let img = image(c) {
                            images.append(img)
                            seen = true
                        }
                    }
                    let text = texts.joined(separator: "\n")
                    out.append([
                        "role": "tool",
                        "tool_call_id": id(b["tool_use_id"] as? String ?? "", p),
                        "content": !text.isEmpty ? text : seen ? "(see attached image)" : "(no tool output)",
                    ])
                case "text":
                    if let t = b["text"] as? String, !t.isEmpty { parts.append(["type": "text", "text": t]) }
                case "image":
                    if let img = image(b) { parts.append(img) }
                default:
                    break
                }
            }
            // tool messages only carry text, so the screenshots follow as the user's
            if !images.isEmpty {
                out.append(["role": "user", "content": [["type": "text", "text": "Attached image(s) from tool result:"]] + images])
            }
            if !parts.isEmpty { out.append(["role": "user", "content": parts]) }
        }
        return out
    }

    // thinking and other anthropic-only blocks stay behind. reasoning and signatures only go
    // back to the provider that made them
    private static func assistant(_ blocks: [[String: Any]], _ p: Provider) -> [String: Any]? {
        var msg: [String: Any] = ["role": "assistant"]
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { msg["content"] = text }
        let calls = blocks.filter { $0["type"] as? String == "tool_use" }.map { b -> [String: Any] in
            let args = (try? JSONSerialization.data(withJSONObject: b["input"] as? [String: Any] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            var c: [String: Any] = [
                "id": id(b["id"] as? String ?? "", p),
                "type": "function",
                "function": ["name": b["name"] as? String ?? "", "arguments": args],
            ]
            if b["via"] as? String == p.id, let x = b["extra_content"] { c["extra_content"] = x }
            return c
        }
        if !calls.isEmpty { msg["tool_calls"] = calls }
        if let r = blocks.first(where: { $0["type"] as? String == "reasoning" && $0["via"] as? String == p.id }) {
            if let d = r["details"] as? [[String: Any]], !d.isEmpty {
                msg["reasoning_details"] = d
            } else if let f = r["field"] as? String, let t = r["text"] as? String, !t.isEmpty {
                msg[f] = t
            }
        }
        if p.alwaysReasoning, msg["reasoning_content"] == nil { msg["reasoning_content"] = "" }
        // an assistant message with neither text nor calls gets refused
        guard msg["content"] != nil || !calls.isEmpty else { return nil }
        if msg["content"] == nil { msg["content"] = NSNull() }
        return msg
    }

    private static func image(_ b: [String: Any]) -> [String: Any]? {
        guard b["type"] as? String == "image", let src = b["source"] as? [String: Any],
              let data = src["data"] as? String else { return nil }
        let type = src["media_type"] as? String ?? "image/jpeg"
        return ["type": "image_url", "image_url": ["url": "data:\(type);base64,\(data)"]]
    }

    // the same id always maps the same way, so a call and its result still match
    static func id(_ s: String, _ p: Provider) -> String {
        guard p.shortIDs else { return s }
        if s.count == 9, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return s }
        var h: UInt64 = 14695981039346656037
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<9).map { _ in
            defer { h /= 62 }
            return chars[Int(h % 62)]
        })
    }

    static func errorMessage(_ data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data), let m = message(obj) { return m }
        let s = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // {"error": {"message"}}, {"error": "..."}, {"message"}, {"detail"}, or gemini's [{"error": ...}]
    private static func message(_ obj: Any) -> String? {
        if let a = obj as? [Any] { return a.first.flatMap(message) }
        if let s = obj as? String { return s }
        guard let d = obj as? [String: Any] else { return nil }
        if let e = d["error"] { return message(e) }
        return d["message"] as? String ?? d["detail"] as? String
    }
}
