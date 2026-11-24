import Foundation
import Network

/// Reproduces the PSN Remote Play push-channel handshake with Apple's own
/// networking stack and logs Sony's complete reply (status line, headers and
/// error body). chiaki-ng's libcurl path only reports "HTTP code 403", so this
/// is how we learn *why* Sony refuses the connection.
enum PSNDiagnostics {
    private static let serverAddrURL = URL(string: "https://mobile-pushcl.np.communication.playstation.net/np/serveraddr?version=2.1&fields=keepAliveStatus&keepAliveStatusType=3")!

    static func run(token: String) async {
        let log = ShiroLog.shared
        log.info("PSN diagnostics: starting")

        // 1. Which push server should we use?
        var req = URLRequest(url: serverAddrURL)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let fqdn: String
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(600), as: UTF8.self)
            log.info("PSN diagnostics: serveraddr HTTP \(status): \(body)")
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let f = json["fqdn"] as? String, !f.isEmpty else { return }
            fqdn = f
        } catch {
            log.error("PSN diagnostics: serveraddr failed: \(error.localizedDescription)")
            return
        }

        // 2. The WebSocket upgrade itself, with the same headers chiaki-ng sends.
        let variants: [(String, [(String, String)])] = [
            ("chiaki headers", [
                ("Sec-WebSocket-Protocol", "np-pushpacket"),
                ("User-Agent", "WebSocket++/0.8.2"),
                ("X-PSN-APP-TYPE", "REMOTE_PLAY"),
                ("X-PSN-APP-VER", "RemotePlay/1.0"),
                ("X-PSN-KEEP-ALIVE-STATUS-TYPE", "3"),
                ("X-PSN-OS-VER", "Windows/10.0"),
                ("X-PSN-PROTOCOL-VERSION", "2.1"),
                ("X-PSN-RECONNECTION", "false"),
            ]),
            ("minimal headers", [
                ("Sec-WebSocket-Protocol", "np-pushpacket"),
                ("X-PSN-PROTOCOL-VERSION", "2.1"),
            ]),
        ]
        for (name, headers) in variants {
            let reply = await upgrade(host: fqdn, token: token, extraHeaders: headers)
            log.info("PSN diagnostics: WebSocket upgrade (\(name)) → \(reply)")
        }
        log.info("PSN diagnostics: done")
    }

    /// Opens TLS to host:443, sends an HTTP/1.1 WebSocket upgrade request and
    /// returns the raw response head + body (truncated), or the error.
    private static func upgrade(host: String, token: String, extraHeaders: [(String, String)]) async -> String {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var lines = [
            "GET /np/pushNotification HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "Authorization: Bearer \(token)",
        ]
        lines += extraHeaders.map { "\($0.0): \($0.1)" }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        let conn = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tls)
        let queue = DispatchQueue(label: "shiro.psn-diagnostics")
        // All callbacks run on `queue`; the box just avoids captured-var mutation.
        final class State { var finished = false; var received = Data() }
        let st = State()
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            func finish(_ s: String) {
                guard !st.finished else { return }
                st.finished = true
                conn.cancel()
                cont.resume(returning: s)
            }
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                    if let d = data { st.received.append(d) }
                    let text = String(decoding: st.received.prefix(1500), as: UTF8.self)
                    // A 101 has no body; any other status usually carries a short one.
                    if text.hasPrefix("HTTP/1.1 101") || isComplete || error != nil || st.received.count > 1400 {
                        finish(text.isEmpty ? "no response (\(error?.localizedDescription ?? "closed"))" : text)
                    } else if text.contains("\r\n\r\n") {
                        // Got the head; give the body a moment to arrive.
                        queue.asyncAfter(deadline: .now() + 1.0) {
                            finish(String(decoding: st.received.prefix(1500), as: UTF8.self))
                        }
                        receive()
                    } else {
                        receive()
                    }
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: request, completion: .contentProcessed { error in
                        if let e = error { finish("send failed: \(e.localizedDescription)") } else { receive() }
                    })
                case .failed(let e):
                    finish("connection failed: \(e.localizedDescription)")
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { finish("timed out; partial: \(String(decoding: st.received.prefix(800), as: UTF8.self))") }
        }
    }
}
