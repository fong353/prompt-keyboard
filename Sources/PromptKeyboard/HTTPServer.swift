import Foundation
import Network

/// 极简 HTTP/1.1 server。只服务局域网,只用做 GET / 和 POST /api/*
/// 不支持 keep-alive、chunked、大文件上传。够用。
final class HTTPServer {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "PromptKeyboard.http")
    var router: ((HTTPRequest) -> HTTPResponse)?

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = false
        let listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, accumulated: Data())
    }

    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("HTTP recv error: %@", "\(error)")
                conn.cancel()
                return
            }
            var buf = accumulated
            if let data { buf.append(data) }

            // 判断 header 是否结束
            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { conn.cancel(); return }
                self.receive(conn, accumulated: buf)
                return
            }

            let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                self.respond(conn, .badRequest())
                return
            }

            let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let requestLine = lines.first else {
                self.respond(conn, .badRequest()); return
            }
            let parts = requestLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else {
                self.respond(conn, .badRequest()); return
            }
            let method = String(parts[0])
            let target = String(parts[1])

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = val
                }
            }

            let bodyStart = headerEnd.upperBound
            let alreadyHaveBody = buf.subdata(in: bodyStart..<buf.endIndex)
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0

            if alreadyHaveBody.count >= contentLength {
                let body = alreadyHaveBody.prefix(contentLength)
                let req = HTTPRequest(method: method, target: target, headers: headers, body: Data(body))
                let resp = self.router?(req) ?? .notFound()
                self.respond(conn, resp)
            } else {
                // 继续读 body
                self.readBody(conn, current: alreadyHaveBody, need: contentLength, method: method, target: target, headers: headers)
            }
        }
    }

    private func readBody(_ conn: NWConnection, current: Data, need: Int, method: String, target: String, headers: [String: String]) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: max(1, need - current.count)) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            var buf = current
            if let data { buf.append(data) }
            if buf.count >= need {
                let req = HTTPRequest(method: method, target: target, headers: headers, body: buf.prefix(need))
                let resp = self.router?(req) ?? .notFound()
                self.respond(conn, resp)
            } else {
                self.readBody(conn, current: buf, need: need, method: method, target: target, headers: headers)
            }
        }
    }

    private func respond(_ conn: NWConnection, _ resp: HTTPResponse) {
        let head = "HTTP/1.1 \(resp.status) \(resp.statusText)\r\n" +
            resp.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") +
            "\r\nContent-Length: \(resp.body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(resp.body)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    var path: String {
        target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }
}

struct HTTPResponse {
    var status: Int
    var statusText: String
    var headers: [String: String]
    var body: Data

    static func ok(_ body: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(status: 200, statusText: "OK",
                     headers: ["Content-Type": contentType, "Cache-Control": "no-store"],
                     body: body)
    }
    static func json(_ obj: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
        return .ok(data, contentType: "application/json; charset=utf-8")
    }
    static func html(_ s: String) -> HTTPResponse {
        .ok(Data(s.utf8), contentType: "text/html; charset=utf-8")
    }
    static func notFound() -> HTTPResponse {
        HTTPResponse(status: 404, statusText: "Not Found",
                     headers: ["Content-Type": "text/plain"],
                     body: Data("not found".utf8))
    }
    static func badRequest() -> HTTPResponse {
        HTTPResponse(status: 400, statusText: "Bad Request",
                     headers: ["Content-Type": "text/plain"],
                     body: Data("bad request".utf8))
    }
}

/// 列出本机所有非 loopback 的 IPv4 地址,挑一个像局域网的展示给用户
enum LocalIP {
    static func primary() -> String? {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            let addr = cur.pointee.ifa_addr.pointee
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0,
               addr.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(cur.pointee.ifa_addr,
                               socklen_t(cur.pointee.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    let name = String(cString: cur.pointee.ifa_name)
                    // 优先 en0/en1 这种物理网卡
                    if name.hasPrefix("en") {
                        addresses.insert(ip, at: 0)
                    } else if !ip.hasPrefix("169.254") {
                        addresses.append(ip)
                    }
                }
            }
            p = cur.pointee.ifa_next
        }
        return addresses.first
    }
}
