import Foundation
import Network

// tiny http/1.1 server on loopback. one request per connection, that's all the app needs.
// every app on the phone can reach loopback, so it stays strict: size caps, a read deadline,
// a connection cap, json only, and the token on every request.
final class Server {
    struct Request {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var token = ""
        var host = ""
        var contentType = ""
        var body = Data()

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    struct Response {
        var status = 200
        var type = "application/json"
        var body = Data()

        static func json(_ obj: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            return Response(status: status, body: data)
        }
    }

    enum Parsed {
        case partial
        case bad(Int, String)
        case done(Request)
    }

    static let maxHeader = 16 * 1024
    static let maxBody = 1 << 20
    static let maxOpen = 16
    static let readDeadline: TimeInterval = 10

    private let listener: NWListener
    private let queue = DispatchQueue(label: "server")
    private let token: String
    private let port: UInt16
    // runs on main, xcuitest wants that
    private let handle: (Request) -> Response
    private var open = 0
    var onFail: ((String) -> Void)?

    init(port: UInt16, token: String, handle: @escaping (Request) -> Response) throws {
        let params = NWParameters.tcp
        // bound to 127.0.0.1 itself, not *:port. on a wildcard bind another app could bind the
        // narrower 127.0.0.1:port and take our connections, token header and all
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
        self.token = token
        self.port = port
        self.handle = handle
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state { self?.onFail?("listener failed: \(err)") }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            guard self.open < Self.maxOpen else {
                conn.cancel()
                return
            }
            self.open += 1
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed: self?.open -= 1
                default: break
                }
            }
            conn.start(queue: self.queue)
            let got = Flag()
            // slow or stuck clients get dropped. only the read has a deadline, a long /act is fine
            self.queue.asyncAfter(deadline: .now() + Self.readDeadline) {
                if !got.set { conn.cancel() }
            }
            self.read(conn, buf: Data(), got: got)
        }
        listener.start(queue: queue)
    }

    private final class Flag { var set = false }

    private func read(_ conn: NWConnection, buf: Data, got: Flag) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buf
            if let data { buf.append(data) }
            switch Self.parse(buf) {
            case .done(let req):
                got.set = true
                self.answer(conn, req)
            case .bad(let status, let msg):
                got.set = true
                self.send(conn, .json(["error": msg], status: status))
            case .partial:
                if done || err != nil { conn.cancel() } else { self.read(conn, buf: buf, got: got) }
            }
        }
    }

    private func answer(_ conn: NWConnection, _ req: Request) {
        // a dns-rebinding page reaches us as its own origin but keeps its own host name
        guard req.host == "127.0.0.1:\(port)" || req.host == "localhost:\(port)" else {
            return send(conn, .json(["error": "bad host"], status: 403))
        }
        guard !token.isEmpty, req.token == token else {
            return send(conn, .json(["error": "bad token"], status: 403))
        }
        // a browser can only send json with a cors preflight, which this server never answers
        if req.method == "POST", !req.contentType.lowercased().hasPrefix("application/json") {
            return send(conn, .json(["error": "send application/json"], status: 415))
        }
        // answered right here so a slow /act on main can't make the app think we're gone
        if req.path == "/status" {
            return send(conn, .json(["ok": true]))
        }
        DispatchQueue.main.async {
            let res = self.handle(req)
            self.queue.async { self.send(conn, res) }
        }
    }

    private func send(_ conn: NWConnection, _ res: Response) {
        var head = "HTTP/1.1 \(res.status) \(res.status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(res.type)\r\n"
        head += "Content-Length: \(res.body.count)\r\n"
        // screenshots and screen text shouldn't land in the app's url cache
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(res.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func parse(_ buf: Data) -> Parsed {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > maxHeader ? .bad(431, "headers too big") : .partial
        }
        guard end.lowerBound <= maxHeader else { return .bad(431, "headers too big") }

        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return .bad(400, "bad request line") }

        var req = Request()
        var length = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "content-length":
                guard let n = Int(value), n >= 0 else { return .bad(400, "bad content-length") }
                guard n <= maxBody else { return .bad(413, "body too big") }
                length = n
            case "x-runner-token": req.token = value
            case "host": req.host = value.lowercased()
            case "content-type": req.contentType = value
            default: break
            }
        }
        let body = buf[end.upperBound...]
        guard body.count >= length else { return .partial }

        req.method = String(first[0])
        let comps = URLComponents(string: String(first[1]))
        req.path = comps?.path ?? "/"
        for item in comps?.queryItems ?? [] { req.query[item.name] = item.value ?? "" }
        req.body = Data(body.prefix(length))
        return .done(req)
    }
}
