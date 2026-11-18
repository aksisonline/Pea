import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Helpers that run off the main actor: finding tools, probing links, fetching metadata.
public enum Tools {
    static let userAgent = "Mozilla/5.0"

    /// Looks for `tool` in the extra locations, then PATH. On Windows `.exe` is appended and a plain file
    /// check is used (`isExecutableFile` is unreliable there, e.g. for winget's app-execution-alias reparse points).
    public static func find(_ tool: String) -> String? {
        resolve(tool, dirs: Platform.extraSearchPaths + pathEntries(ProcessInfo.processInfo.environment),
                windows: Platform.isWindows, exists: defaultExists(windows: Platform.isWindows))
    }

    static func defaultExists(windows: Bool) -> (String) -> Bool {
        { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
            return windows || FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func resolve(_ tool: String, dirs: [String], windows: Bool, exists: (String) -> Bool) -> String? {
        let name = windows && !tool.lowercased().hasSuffix(".exe") ? tool + ".exe" : tool
        for dir in dirs where !dir.isEmpty {
            let path = windows ? joinWindows(dir, name) : (dir.hasSuffix("/") ? dir + name : dir + "/" + name)
            if exists(path) { return path }
        }
        return nil
    }

    private static func joinWindows(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("\\") || dir.hasSuffix("/") ? dir + name : dir + "\\" + name
    }

    /// PATH split into folders. The variable is `Path` on Windows (and env lookups there are case-insensitive);
    /// entries may be quoted or empty.
    static func pathEntries(_ env: [String: String], windows: Bool = Platform.isWindows) -> [String] {
        let value = windows ? env.first { $0.key.uppercased() == "PATH" }?.value : env["PATH"]
        let sep: Character = windows ? ";" : ":"
        return (value ?? "").split(separator: sep).map {
            var d = String($0).trimmingCharacters(in: .whitespaces)
            if windows, d.count >= 2, d.hasPrefix("\""), d.hasSuffix("\"") { d = String(d.dropFirst().dropLast()) }
            return d
        }.filter { !$0.isEmpty }
    }

    public static var ytdlp: String? { find("yt-dlp") }
    public static var ffmpeg: String? { find("ffmpeg") }
    public static var toolsInstalled: Bool { ytdlp != nil && ffmpeg != nil }

    /// GUI apps get a bare PATH; add the usual tool locations so yt-dlp can find ffmpeg and deno.
    /// On Windows also force UTF-8 for Python's piped stdout/stderr (otherwise the ANSI code page mangles titles).
    public static var environment: [String: String] {
        environment(from: ProcessInfo.processInfo.environment, extra: Platform.extraSearchPaths, windows: Platform.isWindows)
    }

    static func environment(from base: [String: String], extra: [String], windows: Bool) -> [String: String] {
        var e = base
        let key = windows ? (e.keys.first { $0.uppercased() == "PATH" } ?? "Path") : "PATH"
        e[key] = (extra + [e[key] ?? ""]).joined(separator: windows ? ";" : ":")
        if windows {
            e["PYTHONUTF8"] = "1"
            e["PYTHONIOENCODING"] = "utf-8"
        }
        return e
    }

    /// Runs a tool to completion and returns trimmed stdout, or nil on failure / timeout.
    /// Blocks a GCD thread rather than the cooperative pool.
    public static func capture(_ bin: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 25) async -> String? {
        guard let data = await captureData(bin, args, stdin: stdin, timeout: timeout) else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func captureData(_ bin: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 25) async -> Data? {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                guard let child = try? ChildProcessFactory.spawn(SpawnOptions(executable: bin, arguments: args,
                                                                               environment: environment, stdin: stdin)) else {
                    c.resume(returning: nil); return
                }
                let killer = DispatchWorkItem { child.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                var data = Data()
                while true {
                    let chunk = child.readStdout()
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                let status = child.wait()
                killer.cancel()
                c.resume(returning: status == 0 ? data : nil)
            }
        }
    }

    /// 16×16 RGB24 sample of an encoded image, via ffmpeg.
    static func sampleImage(_ data: Data) async -> [UInt8]? {
        guard let ffmpeg else { return nil }
        guard let raw = await captureData(ffmpeg, ["-v", "error", "-i", "pipe:0", "-vf", "scale=16:16",
                                                    "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"],
                                          stdin: data) else { return nil }
        return [UInt8](raw)
    }

    // MARK: Metadata

    /// Title + artwork for a link: Spotify via its public page, everything else via yt-dlp.
    public static func fetchMeta(_ url: URL) async -> Meta {
        if Source.of(url).isSpotify {
            guard let i = await spotifyInfo(url) else { return Meta() }
            let art = await i.image.asyncFlatMap { await image($0) }
            return Meta(title: i.artist.isEmpty ? i.title : "\(i.title) — \(i.artist)", art: art)
        }
        guard let bin = ytdlp,
              let out = await capture(bin, ["--no-playlist", "--no-warnings", "--skip-download", "--playlist-items", "1",
                                            "--print", "%(title)s", "--print", "%(thumbnail)s", url.absoluteString])
        else { return Meta() }
        let lines = out.components(separatedBy: "\n")
        let art = await URL(string: lines.count > 1 ? lines[1] : "").asyncFlatMap { await image($0) }
        return Meta(title: lines.first, art: art)
    }

    /// Spotify can't be downloaded directly; read the track's title + artist from its public page.
    public static func spotifyInfo(_ url: URL) async -> (title: String, artist: String, image: URL?)? {
        guard url.path.contains("/track/"),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.query = nil
        guard let clean = c.url else { return nil }
        var req = URLRequest(url: clean, timeoutInterval: 12)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await HTTP.fetch(req), let html = String(data: data, encoding: .utf8) else { return nil }

        func meta(_ key: String) -> String? {
            let pattern = "<meta (?:property|name)=\"\(key)\" content=\"([^\"]*)\""
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { return nil }
            return String(html[r])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#x27;", with: "'")
                .replacingOccurrences(of: "&#39;", with: "'")
        }
        guard let title = meta("og:title") else { return nil }
        let artist = meta("music:musician_description")
            ?? meta("og:description")?.components(separatedBy: " · ").first
            ?? ""
        return (title, artist, meta("og:image").flatMap { URL(string: $0) })
    }

    static func image(_ url: URL) async -> Artwork? {
        guard let (data, _) = try? await HTTP.fetch(URLRequest(url: url, timeoutInterval: 12)) else { return nil }
        return await Artwork.make(data)
    }

    // MARK: Direct files

    /// True when the URL serves a plain file (anything that isn't an HTML page).
    public static func isDirectFile(_ url: URL) async -> Bool {
        func verdict(_ resp: URLResponse) -> Bool? {
            guard let h = resp as? HTTPURLResponse, h.statusCode < 400 else { return nil }
            guard let mime = resp.mimeType?.lowercased() else { return false }
            return mime != "text/html" && mime != "application/xhtml+xml"
        }
        var head = URLRequest(url: url, timeoutInterval: 10)
        head.httpMethod = "HEAD"
        head.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await HTTP.fetch(head), let v = verdict(resp) { return v }

        // Some servers reject HEAD; ask for a single byte of a GET instead.
        var get = URLRequest(url: url, timeoutInterval: 10)
        get.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, resp) = try? await HTTP.fetch(get) else { return false }
        return verdict(resp) ?? false
    }
}

extension Optional {
    func asyncFlatMap<T>(_ f: (Wrapped) async -> T?) async -> T? {
        guard let v = self else { return nil }
        return await f(v)
    }
}

/// Small portable wrapper over the HTTP transport (see Transport.swift for which one is used where).
enum HTTP {
    static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let curl = Transport.curl { return try await curl.fetch(request) }
        return try await fetchURLSession(request)
    }

    static func fetchURLSession(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                let t = URLSession.shared.dataTask(with: request) { data, resp, err in
                    if let err { c.resume(throwing: err) }
                    else if let data, let resp { c.resume(returning: (data, resp)) }
                    else { c.resume(throwing: URLError(.unknown)) }
                }
                box.set(t)
                t.resume()
            }
        } onCancel: { box.cancel() }
    }

    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func set(_ t: URLSessionTask) { lock.lock(); task = t; let c = cancelled; lock.unlock(); if c { t.cancel() } }
        func cancel() { lock.lock(); cancelled = true; let t = task; lock.unlock(); t?.cancel() }
    }
}
