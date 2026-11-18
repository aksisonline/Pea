import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Helpers that run off the main actor: finding tools, probing links, fetching metadata.
public enum Tools {
    static let userAgent = "Mozilla/5.0"

    public static func find(_ tool: String) -> String? {
        let dirs = Platform.extraSearchPaths
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: Character(Platform.pathSeparator)).map(String.init)
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(tool + Platform.exeSuffix)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public static var ytdlp: String? { find("yt-dlp") }
    public static var ffmpeg: String? { find("ffmpeg") }
    public static var toolsInstalled: Bool { ytdlp != nil && ffmpeg != nil }

    /// GUI apps get a bare PATH; add the usual tool locations so yt-dlp can find ffmpeg and deno.
    public static var environment: [String: String] {
        var e = ProcessInfo.processInfo.environment
        let key = Platform.isWindows ? (e.keys.first { $0.uppercased() == "PATH" } ?? "Path") : "PATH"
        e[key] = (Platform.extraSearchPaths + [e[key] ?? ""]).joined(separator: Platform.pathSeparator)
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
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = args
                p.environment = environment
                let out = Pipe(), inPipe = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
                guard (try? p.run()) != nil else { c.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                if let stdin {
                    // Feed stdin from its own thread so a full pipe can't deadlock the read below.
                    DispatchQueue.global().async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                c.resume(returning: p.terminationStatus == 0 ? data : nil)
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

/// Small portable wrapper over completion-handler URLSession (the async APIs differ across platforms).
enum HTTP {
    static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
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
