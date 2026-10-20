import Foundation
import Network

// tiny http/1.1 server on loopback. one request per connection, that's all the app needs.
final class Server {
    struct Request {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var token = ""
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

    private let listener: NWListener
    private let queue = DispatchQueue(label: "server")
    // runs on main, xcuitest wants that
    private let handle: (Request) -> Response

    init(port: UInt16, handle: @escaping (Request) -> Response) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.handle = handle
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.read(conn, buf: Data())
        }
        listener.start(queue: queue)
    }

    private func read(_ conn: NWConnection, buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buf
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                DispatchQueue.main.async {
                    let res = self.handle(req)
                    self.queue.async { self.send(conn, res) }
                }
            } else if done || err != nil {
                conn.cancel()
            } else {
                self.read(conn, buf: buf)
            }
        }
    }

    private func send(_ conn: NWConnection, _ res: Response) {
        var head = "HTTP/1.1 \(res.status) \(res.status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(res.type)\r\n"
        head += "Content-Length: \(res.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(res.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // nil until the whole request (headers + body) is in
    static func parse(_ buf: Data) -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }

        var length = 0
        var token = ""
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "content-length": length = Int(value) ?? 0
            case "x-runner-token": token = value
            default: break
            }
        }
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }

        var req = Request()
        req.method = String(first[0])
        let comps = URLComponents(string: String(first[1]))
        req.path = comps?.path ?? "/"
        for item in comps?.queryItems ?? [] { req.query[item.name] = item.value ?? "" }
        req.token = token
        req.body = Data(body.prefix(length))
        return req
    }
}
