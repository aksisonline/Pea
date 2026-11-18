import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How segment downloads are carried. URLSession everywhere except Windows, where swift-corelibs-foundation's
/// libcurl-based URLSession has reported random -1001 timeouts (Swift forums 81259: only on Windows, requests
/// always run to the timeout; the only known fix was a custom FoundationNetworking build with HTTP/2), crashes when a
/// task times out or is cancelled (libdispatch socket-source teardown, forums 64795 / PR #4859) and
/// no HTTP/2 in the stock toolchain's libcurl. `curl.exe` has shipped in System32 since Windows 10 1803, speaks
/// HTTP/2 and uses Schannel, so Windows uses it by default. Override with DALL_TRANSPORT=urlsession|curl.
protocol DownloadTransport: AnyObject, Sendable {
    func download(_ request: URLRequest,
                  onBytes: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void) async throws -> (URL, URLResponse)
    func invalidate()
}

enum Transport {
    /// The curl transport when it should be used, else nil (use URLSession).
    static var curl: CurlTransport? {
        let choice = ProcessInfo.processInfo.environment["DALL_TRANSPORT"]?.lowercased()
        if choice == "urlsession" { return nil }
        guard choice == "curl" || Platform.isWindows, let path = curlPath() else { return nil }
        return CurlTransport(curl: path)
    }

    static func curlPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["DALL_CURL"], FileManager.default.fileExists(atPath: p) { return p }
        if Platform.isWindows {
            let root = env["SystemRoot"] ?? env["windir"] ?? "C:\\Windows"
            let sys = root + "\\System32\\curl.exe"
            if FileManager.default.fileExists(atPath: sys) { return sys }
        }
        return Tools.find("curl")
    }
}

/// Drives `curl` as a child process. Stateless; each call is one process, killed with the awaiting Task.
final class CurlTransport: DownloadTransport, @unchecked Sendable {
    let curl: String
    init(curl: String) { self.curl = curl }
    func invalidate() {}

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (file, resp) = try await perform(request, onBytes: { _, _ in }, head: request.httpMethod == "HEAD",
                                             totalTimeout: request.timeoutInterval)
        defer { try? FileManager.default.removeItem(at: file) }
        return (try Data(contentsOf: file), resp)
    }

    func download(_ request: URLRequest,
                  onBytes: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        try await perform(request, onBytes: onBytes, head: false, totalTimeout: nil)
    }

    static func arguments(_ request: URLRequest, body: String, headers: String, head: Bool, totalTimeout: TimeInterval?) -> [String] {
        var a = ["--silent", "--show-error", "--location", "--max-redirs", "10", "--globoff",
                 "--proto", "=http,https", "--proto-redir", "=http,https",
                 "--connect-timeout", "20",
                 // Abort a stalled transfer (< 1 KB/s for 30 s); the caller's retry logic takes it from there.
                 "--speed-limit", "1024", "--speed-time", "30",
                 "--dump-header", headers, "--output", body]
        if let t = totalTimeout, t > 0 { a += ["--max-time", String(Int(t.rounded(.up)))] }
        if head { a.append("--head") }
        else if let m = request.httpMethod, m != "GET" { a += ["--request", m] }
        for (k, v) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) { a += ["--header", "\(k): \(v)"] }
        a += ["--url", request.url?.absoluteString ?? ""]
        return a
    }

    private func perform(_ request: URLRequest, onBytes: @escaping @Sendable (Int64, Int64) -> Void, head: Bool,
                         totalTimeout: TimeInterval?) async throws -> (URL, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let body = HTTPDownload.tempFile(), headers = HTTPDownload.tempFile()
        defer { try? FileManager.default.removeItem(at: headers) }
        let args = Self.arguments(request, body: Platform.nativePath(body), headers: Platform.nativePath(headers),
                                  head: head, totalTimeout: totalTimeout)
        let child: ChildProcess
        do {
            child = try ChildProcessFactory.spawn(SpawnOptions(executable: curl, arguments: args,
                                                               environment: ProcessInfo.processInfo.environment,
                                                               captureStdout: true, captureStderr: false))
        } catch { throw URLError(.cannotConnectToHost) }

        // Progress: curl writes straight to the file, so watch its size.
        let watcher = Task {
            var expected: Int64 = -1
            while !Task.isCancelled {
                if expected < 0, let text = try? String(contentsOf: headers, encoding: .utf8),
                   let r = Self.parseHeaders(text, url: url) { expected = r.expectedContentLength }
                let size = (try? FileManager.default.attributesOfItem(atPath: body.path)[.size] as? Int64) ?? 0
                onBytes(size, expected)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                DispatchQueue.global().async {
                    while !child.readStdout().isEmpty {}   // curl prints nothing; this just waits for the pipe to close
                    c.resume(returning: child.wait())
                }
            }
        } onCancel: { child.terminate() }
        watcher.cancel()

        if Task.isCancelled { try? FileManager.default.removeItem(at: body); throw CancellationError() }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: body)
            throw URLError(Self.urlErrorCode(forCurlExit: status))
        }
        guard let text = try? String(contentsOf: headers, encoding: .utf8), let resp = Self.parseHeaders(text, url: url) else {
            try? FileManager.default.removeItem(at: body)
            throw URLError(.badServerResponse)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: body.path)[.size] as? Int64) ?? 0
        onBytes(size, resp.expectedContentLength)
        return (body, resp)
    }

    static func urlErrorCode(forCurlExit code: Int32) -> URLError.Code {
        switch code {
        case 6: return .cannotFindHost
        case 7: return .cannotConnectToHost
        case 28: return .timedOut
        case 35, 51, 58, 60, 77, 83: return .secureConnectionFailed
        case 47: return .httpTooManyRedirects
        case 56, 52, 55: return .networkConnectionLost
        default: return .unknown
        }
    }

    /// The final response in a `--dump-header` file (redirects and 100-continue produce several blocks).
    static func parseHeaders(_ text: String, url: URL) -> HTTPURLResponse? {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .filter { $0.hasPrefix("HTTP/") }
        guard let last = blocks.last else { return nil }
        let lines = last.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[k] = fields[k].map { $0 + ", " + v } ?? v
        }
        return HTTPURLResponse(url: url, statusCode: code, httpVersion: String(parts[0]), headerFields: fields)
    }
}
