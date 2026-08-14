import Foundation
import Darwin
import os

/// Local OTA install server (semi-local, Feather-style).
///
/// `itms-services` requires an HTTPS manifest URL that iOS trusts. The public
/// `*.backloop.dev` leaf is now issued under Let's Encrypt YR1 / ISRG Root YR,
/// which Apple's trust store does not include — Safari shows "This Connection
/// Is Not Private". Instead we:
///
/// 1. Serve the IPA over plain HTTP on `127.0.0.1` (loopback; no cert needed).
/// 2. Point `itms-services` at a remote HTTPS plist from `api.palera.in`
///    (`genPlist`) whose `software-package` URL is our local IPA.
///
/// Same approach Feather uses for its "semi-local" / server-method-1 install.
final class LocalInstallServer: @unchecked Sendable {
    private struct State {
        var listenerFD: Int32 = -1
        var running = false
        var port: UInt16 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private var ipaURL: URL?
    private var bundleId = ""
    private var bundleVersion = "1.0"
    private var title = "App"

    /// Local loopback base (plain HTTP). Used for the IPA and the Safari
    /// handoff page — never for the itms-services manifest URL.
    var installBaseURL: String {
        "http://127.0.0.1:\(port)"
    }

    var payloadURL: String {
        "\(installBaseURL)/app.ipa"
    }

    /// Trusted HTTPS manifest URL (plistserver). This is what itms-services
    /// actually fetches.
    var remoteManifestURL: String {
        var comps = URLComponents(string: "https://api.palera.in/genPlist")!
        comps.queryItems = [
            URLQueryItem(name: "bundleid", value: bundleId),
            URLQueryItem(name: "name", value: title),
            URLQueryItem(name: "version", value: bundleVersion),
            URLQueryItem(name: "fetchurl", value: payloadURL),
        ]
        return comps.url?.absoluteString ?? "https://api.palera.in/genPlist"
    }

    var port: UInt16 {
        state.withLock { $0.port }
    }

    /// Starts the loopback HTTP server and returns the bound port.
    func start(ipa: URL, bundleId: String, bundleVersion: String, title: String) async throws -> UInt16 {
        self.ipaURL = ipa
        self.bundleId = bundleId
        self.bundleVersion = bundleVersion.isEmpty ? "1.0" : bundleVersion
        self.title = title.isEmpty ? "App" : title

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }
        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getsockname(fd, withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &len) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }
        let boundPort = UInt16(boundAddr.sin_port.bigEndian)

        state.withLock {
            $0.listenerFD = fd
            $0.port = boundPort
            $0.running = true
        }

        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "forgesign.installserver"
        t.start()

        return boundPort
    }

    func stop() {
        let fd = state.withLock { state -> Int32 in
            state.running = false
            let fd = state.listenerFD
            state.listenerFD = -1
            return fd
        }
        if fd >= 0 { close(fd) }
    }

    // MARK: Accept loop

    private func acceptLoop(_ fd: Int32) {
        while true {
            let shouldRun = state.withLock { $0.running }
            guard shouldRun else { break }

            let client = accept(fd, nil, nil)
            if client >= 0 {
                handleConnection(client)
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        var buffer = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 64 * 1024 {
            let n = recv(fd, &raw, raw.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: raw[0..<n])
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
              let request = String(data: buffer.subdata(in: 0..<headerRange.lowerBound), encoding: .utf8) else {
            return
        }

        let lines = request.split(separator: "\r\n").map(String.init)
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        let method = parts.first ?? "GET"
        let path = parts.count > 1 ? parts[1] : "/"
        let headOnly = method == "HEAD"

        // The iOS installer retries with `Range:` on flaky connections; honour
        // single-range byte requests so downloads resume instead of restarting.
        var range: (start: UInt64, end: UInt64?)?
        for line in lines.dropFirst() {
            let lowered = line.lowercased()
            if lowered.hasPrefix("range: bytes=") {
                let spec = line.dropFirst("range: bytes=".count)
                let halves = spec.split(separator: "-", maxSplits: 1).map(String.init)
                if halves.count == 2, let start = UInt64(halves[0]) {
                    range = (start, UInt64(halves[1]))
                }
            }
        }

        if path.hasPrefix("/app.ipa") {
            if let ipa = ipaURL, FileManager.default.fileExists(atPath: ipa.path) {
                sendFile(fd, url: ipa, headOnly: headOnly, range: range)
            } else {
                sendResponse(fd, status: "404 Not Found", contentType: "text/plain",
                             body: Data("not found".utf8), headOnly: false)
            }
        } else if path.hasPrefix("/install") {
            sendResponse(fd, status: "200 OK", contentType: "text/html",
                         body: Data(installPage().utf8), headOnly: false)
        } else if path.hasPrefix("/health") {
            sendResponse(fd, status: "200 OK", contentType: "text/plain",
                         body: Data("ok".utf8), headOnly: headOnly)
        } else {
            sendResponse(fd, status: "404 Not Found", contentType: "text/plain",
                         body: Data("not found".utf8), headOnly: false)
        }
    }

    var onIPADelivered: (() -> Void)?

    private func sendAll(_ fd: Int32, _ data: Data) {
        var sent = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private func sendResponse(_ fd: Int32, status: String, contentType: String, body: Data, headOnly: Bool) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        if !headOnly { response.append(body) }
        sendAll(fd, response)
    }

    private func sendFile(_ fd: Int32, url: URL, headOnly: Bool, range: (start: UInt64, end: UInt64?)?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            sendResponse(fd, status: "404 Not Found", contentType: "text/plain", body: Data(), headOnly: false)
            return
        }
        let fileSize = handle.seekToEndOfFile()

        // Resolve a satisfiable [start, end] window; otherwise full body.
        var offset: UInt64 = 0
        var remaining: UInt64 = fileSize
        var status = "200 OK"
        var rangeLine = ""
        if let range, range.start < fileSize {
            let end = min(range.end ?? (fileSize - 1), fileSize - 1)
            offset = range.start
            remaining = end - range.start + 1
            status = "206 Partial Content"
            rangeLine = "Content-Range: bytes \(range.start)-\(end)/\(fileSize)\r\n"
        }

        handle.seek(toFileOffset: offset)
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: application/octet-stream\r\n"
        header += "Content-Length: \(remaining)\r\n"
        header += rangeLine
        header += "Accept-Ranges: bytes\r\n"
        header += "Connection: close\r\n\r\n"
        sendAll(fd, Data(header.utf8))
        if headOnly {
            try? handle.close()
            return
        }
        while remaining > 0 {
            let want = min(UInt64(1024 * 1024), remaining)
            let chunk = handle.readData(ofLength: Int(want))
            if chunk.isEmpty { break }
            remaining -= UInt64(chunk.count)
            sendAll(fd, chunk)
        }
        try? handle.close()
        // Only a fully served file counts as delivered (a 206 may be a retry).
        if offset == 0 {
            onIPADelivered?()
        }
    }

    /// Safari-facing page. Redirects into itms-services with the *remote*
    /// HTTPS plist URL (never a local TLS URL).
    private func installPage() -> String {
        let itms = itmsServicesURL
        // Titles come from filenames; escape before embedding in HTML.
        func html(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "'", with: "&#39;")
        }
        let safeTitle = html(title)
        let safeItms = html(itms)
        return """
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
        <h1>Installing \(safeTitle)…</h1>
        <p>If no prompt appears, tap Install below. Keep ForgeSign open.</p>
        <a id="install" href="\(safeItms)">Install</a>
        </div>
        <script>setTimeout(function(){ window.location.assign("\(itms)"); }, 250);</script>
        </body></html>
        """
    }

    var itmsServicesURL: String {
        // Encode the entire HTTPS plist URL for the itms-services query value
        // (same encoding Feather uses for its external/semi-local link).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = remoteManifestURL.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? remoteManifestURL
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }
}
