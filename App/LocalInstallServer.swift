import Foundation
import Network
import Darwin

/// A minimal local HTTP server that serves a signed IPA plus an `itms-services`
/// manifest so iOS will install the app directly on-device.
///
/// iOS OTA installation normally requires HTTPS manifests, but it accepts
/// plain HTTP for localhost — the same loopback behaviour the App Store /
/// AltStore-type installers rely on. The manifest and IPA are therefore served
/// as `http://127.0.0.1:<port>/...` on this app's own loopback address.
///
/// NOTE on TLS: the previous implementation served these over HTTPS using the
/// embedded `*.backloop.dev` identity. That certificate now chains to Let's
/// Encrypt's new `ISRG Root YR` root, which older iOS trust stores do not
/// include, so the installer aborted the manifest fetch with a TLS error. Plain
/// loopback HTTP has no certificate-dependency and works on every iOS version.
///
/// Flow: ForgeSign signs the IPA, starts this server, then opens
/// `itms-services://?action=download-manifest&url=http://127.0.0.1:<port>/manifest.plist`.
final class LocalInstallServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "forgesign.installserver")
    private(set) var port: UInt16 = 0

    private var ipaURL: URL?
    private var bundleId = ""
    private var bundleVersion = "1.0"
    private var title = "App"

    /// Base URL (scheme+host+port) the installer uses to reach this server.
    /// The manifest and IPA are served over loopback plain HTTP so the fetch
    /// carries no TLS/trust dependency (see the header for why that matters).
    var installBaseURL: String {
        "http://127.0.0.1:\(port)"
    }

    var manifestURL: String {
        "\(installBaseURL)/manifest.plist"
    }

    /// Starts the server and returns the bound port.
    func start(ipa: URL, bundleId: String, bundleVersion: String, title: String) async throws -> UInt16 {
        self.ipaURL = ipa
        self.bundleId = bundleId
        self.bundleVersion = bundleVersion.isEmpty ? "1.0" : bundleVersion
        self.title = title

        // Loopback HTTP, mirroring the on-device installer behaviour of
        // AltStore-class tools. No TLS handshake, no trust anchors to fail.
        let params = NWParameters()
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)
        self.listener = l
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }

        let q = queue
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let error):
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            l.start(queue: q)
        }
        self.port = boundPort
        return boundPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: 0..<range.lowerBound)
                let request = String(data: headerData, encoding: .utf8) ?? ""
                self.respond(conn, request: request)
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receiveRequest(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, request: String) {
        let lines = request.split(separator: "\r\n").map(String.init)
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        let method = parts.first ?? "GET"
        let path = parts.count > 1 ? parts[1] : "/"

        if path.hasPrefix("/manifest.plist") {
            send(conn, status: "200 OK", contentType: "application/xml", body: manifestData(), headOnly: method == "HEAD")
        } else if path.hasPrefix("/app.ipa") {
            if let ipa = ipaURL, FileManager.default.fileExists(atPath: ipa.path) {
                sendFile(conn, url: ipa, headOnly: method == "HEAD")
            } else {
                send(conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8), headOnly: false)
            }
        } else if path.hasPrefix("/install") {
            // Fallback for iOS versions where opening itms-services:// directly
            // from an app is gated: Safari lands here and is redirected into
            // the installer by the script below.
            send(conn, status: "200 OK", contentType: "text/html", body: Data(installPage().utf8), headOnly: false)
        } else {
            send(conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8), headOnly: false)
        }
    }

    /// Called on the server queue after the IPA has been fully streamed.
    var onIPADelivered: (() -> Void)?

    private func installPage() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Installing \(title)</title>
        <style>body{font-family:-apple-system,sans-serif;color:#1c1c1e;margin:0;min-height:100vh;
        display:flex;justify-content:center;align-items:center;background:#f7f9fd;overflow:hidden}
        .bloom{position:fixed;border-radius:50%;filter:blur(70px);pointer-events:none;z-index:0}
        .b1{width:80vw;height:80vw;background:rgba(0,122,255,.14);top:-30vw;left:-25vw}
        .b2{width:65vw;height:65vw;background:rgba(107,199,184,.14);bottom:-20vw;right:-18vw}
        .card{position:relative;z-index:1;background:rgba(255,255,255,.55);
        backdrop-filter:blur(24px) saturate(1.5);-webkit-backdrop-filter:blur(24px) saturate(1.5);
        border:1px solid rgba(0,0,0,.08);border-radius:22px;padding:28px 24px;max-width:320px;
        text-align:center;box-shadow:0 18px 40px rgba(0,0,0,.12)}
        h1{font-size:18px;font-weight:600;margin:0 0 6px}
        p{font-size:14px;color:#6d6d72;margin:0}
        a{display:inline-block;margin-top:16px;padding:12px 28px;border-radius:14px;color:#fff;
        background:linear-gradient(135deg,#338fff 0%,#0066e6 100%);text-decoration:none;
        font-weight:600;font-size:15px;box-shadow:0 8px 16px rgba(0,122,255,.28)}
        @media (prefers-color-scheme:dark){
        body{background:#242830;color:#ededef}
        .b1{background:rgba(56,153,255,.18)}.b2{background:rgba(107,199,184,.13)}
        .card{background:rgba(255,255,255,.10);border-color:rgba(255,255,255,.15)}
        p{color:#b4b4ba}}
        </style>
        </head>
        <body><div class="bloom b1"></div><div class="bloom b2"></div><div class="card">
        <h1>Installing \(title)…</h1>
        <p>Accept the prompt to start the install.</p>
        <a href="\(itmsServicesURL)">Install again</a>
        </div>
        <script>window.location = "\(itmsServicesURL)";</script>
        </body></html>
        """
    }

    var itmsServicesURL: String {
        let manifest = "\(installBaseURL)/manifest.plist"
        // Keep the URL readable (like Feather does) while still escaping any
        // character that would break the outer query string.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/:")
        let encoded = manifest.addingPercentEncoding(withAllowedCharacters: allowed) ?? manifest
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }

    private func send(_ conn: NWConnection, status: String, contentType: String, body: Data, headOnly: Bool) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        if !headOnly { response.append(body) }
        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func sendFile(_ conn: NWConnection, url: URL, headOnly: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            send(conn, status: "404 Not Found", contentType: "text/plain", body: Data(), headOnly: false)
            return
        }
        let fileSize = handle.seekToEndOfFile()
        handle.seek(toFileOffset: 0)
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/octet-stream\r\n"
        header += "Content-Length: \(fileSize)\r\n"
        header += "Connection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            if headOnly {
                try? handle.close()
                conn.cancel()
            } else {
                self?.sendChunks(conn, handle: handle)
            }
        })
    }

    private func sendChunks(_ conn: NWConnection, handle: FileHandle) {
        let chunk = handle.readData(ofLength: 1024 * 1024)
        if chunk.isEmpty {
            try? handle.close()
            // Give the TLS stack a moment to flush the final records and
            // close_notify before tearing the connection down.
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                conn.cancel()
                self?.onIPADelivered?()
            }
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            self?.sendChunks(conn, handle: handle)
        })
    }

    // MARK: Manifest

    private func manifestData() -> Data {
        let ipaURLString = "\(installBaseURL)/app.ipa"
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>items</key>
            <array>
                <dict>
                    <key>assets</key>
                    <array>
                        <dict>
                            <key>kind</key>
                            <string>software-package</string>
                            <key>url</key>
                            <string>\(ipaURLString)</string>
                        </dict>
                    </array>
                    <key>metadata</key>
                    <dict>
                        <key>bundle-identifier</key>
                        <string>\(bundleId)</string>
                        <key>bundle-version</key>
                        <string>\(bundleVersion)</string>
                        <key>kind</key>
                        <string>software</string>
                        <key>title</key>
                        <string>\(title)</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
        return Data(manifest.utf8)
    }
}
