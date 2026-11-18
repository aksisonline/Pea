import Foundation

public struct Job: Sendable {
    public var target: String
    public var output: String
    public var kind: Kind
    public var quality: Quality
    public var format: AudioFormat
    /// Index into `YtDlp.clients`; bumped when YouTube answers 403.
    public var attempt = 0

    public init(target: String, output: String, kind: Kind, quality: Quality, format: AudioFormat, attempt: Int = 0) {
        self.target = target; self.output = output; self.kind = kind
        self.quality = quality; self.format = format; self.attempt = attempt
    }
}

public struct YtDlpOutcome: Sendable {
    public var status: Int32
    public var path: String?
    public var error: String?
    public init(status: Int32, path: String? = nil, error: String? = nil) {
        self.status = status; self.path = path; self.error = error
    }
}

public enum YtDlp {
    /// YouTube clients tried in order; some formats 403 on one but not another.
    public static let clients: [String?] = [nil, "web_embedded", "tv_simply", "web_music"]

    public static func arguments(_ job: Job, temp: String) -> [String] {
        var a = [
            "--no-playlist", "--no-warnings", "--quiet", "--progress", "--newline", "--no-simulate",
            "--embed-metadata",
            "--progress-template",
            "download:PROG %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
            "--print", "after_move:filepath",
            "-P", Platform.downloadsDirectory.path, "-P", "temp:" + temp, "-o", job.output,
        ]
        if let c = clients[min(job.attempt, clients.count - 1)] {
            a += ["--extractor-args", "youtube:player_client=\(c)"]
        }
        switch job.kind {
        case .video:
            let res = ["res", "res:1080", "res:480"][Quality.allCases.firstIndex(of: job.quality) ?? 0]
            a += ["--merge-output-format", "mp4", "-S", res, "--embed-thumbnail", "--convert-thumbnails", "jpg"]
        case .audio:
            a += ["-f", "ba/b", "-x", "--audio-format", job.format.rawValue.lowercased()]
            guard job.format != .wav else { break }   // lossless, and WAV can't hold cover art
            switch (job.format, job.quality) {
            case (.mp3, .original): a += ["--audio-quality", "320K"]
            case (_, .high): a += ["--audio-quality", "192K"]
            case (_, .small): a += ["--audio-quality", "96K"]
            default: break                              // Opus original keeps the source stream
            }
            // Square-cropped cover art embedded in the file.
            a += ["--embed-thumbnail", "--convert-thumbnails", "png",
                  "--ppa", "ThumbnailsConvertor+ffmpeg_o:-vf crop=\"'min(iw,ih)':'min(iw,ih)'\""]
        }
        a.append(job.target)
        return a
    }
}

/// One yt-dlp invocation. Streams stdout/stderr to the end before reporting, so the final
/// `after_move:filepath` line and any trailing ERROR can't be lost to a termination race.
public final class YtDlpRun: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.terminate() }
    }

    public func run(_ job: Job, onProgress: @escaping @Sendable (Double) -> Void) async -> YtDlpOutcome {
        guard let bin = Tools.ytdlp else {
            return YtDlpOutcome(status: -1, error: "yt-dlp isn’t installed")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dall-" + UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: temp) }

        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = YtDlp.arguments(job, temp: temp)
        process.environment = Tools.environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        guard !lock.withLock({ cancelled }), (try? process.run()) != nil else {
            return YtDlpOutcome(status: -1, error: "Couldn’t start yt-dlp")
        }
        if lock.withLock({ cancelled }) { process.terminate() }

        // Both pipes are read to EOF on their own threads: nothing is lost, and neither can fill and stall yt-dlp.
        let errLines = LineStream(err.fileHandleForReading)
        let outLines = LineStream(out.fileHandleForReading)
        var path: String?
        var tracker = ProgressTracker(weightedVideo: job.kind == .video)
        for await line in outLines.lines {
            if line.hasPrefix("PROG "), let p = tracker.feed(line) { onProgress(p) }
            else if line.hasPrefix("/") || line.dropFirst().hasPrefix(":\\") { path = line }   // POSIX or Windows path
        }
        var error: String?
        for await line in errLines.lines where line.hasPrefix("ERROR") { error = line }
        process.waitUntilExit()
        return YtDlpOutcome(status: process.terminationStatus, path: path, error: error)
    }
}

/// A pipe as an async sequence of lines (FileHandle.bytes isn't available everywhere).
final class LineStream: @unchecked Sendable {
    let lines: AsyncStream<String>

    init(_ handle: FileHandle) {
        lines = AsyncStream { continuation in
            let thread = Thread {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData          // blocks until data or EOF
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                            .trimmingCharacters(in: .whitespaces)
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if !line.isEmpty { continuation.yield(line) }
                    }
                }
                let rest = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { continuation.yield(rest) }
                continuation.finish()
            }
            thread.start()
        }
    }
}

/// Turns yt-dlp's per-stream progress into one overall fraction. A video job downloads
/// video then audio, restarting at 0% for the second stream; weight them 90/10.
struct ProgressTracker {
    let weightedVideo: Bool
    private var last = 0.0
    private var stream = 0

    init(weightedVideo: Bool) { self.weightedVideo = weightedVideo }

    mutating func feed(_ line: String) -> Double? {
        let f = line.dropFirst(5).split(separator: " ").map { Double($0) }
        guard f.count >= 3, let done = f[0], let total = f[1] ?? f[2], total > 0 else { return nil }
        let frac = min(done / total, 1)
        if frac < last - 0.3 { stream += 1 }
        last = frac
        guard weightedVideo else { return frac }
        return stream == 0 ? frac * 0.9 : 0.9 + frac * 0.1
    }
}
