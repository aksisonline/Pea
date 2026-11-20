import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Plain HTTP(S) file download, modelled on aria2's segmented transfer (`-x16 -s16 -k1M`):
/// probe for byte-range support, split the file into up to 16 segments of at least 1 MiB,
/// fetch them in parallel, retry a broken segment, then stitch them together.
/// Servers without range support (or small files) use a single stream.
/// Structured concurrency throughout: cancel the calling Task to stop everything and clean up.
public enum HTTPDownload {
    private static let minSegment: Int64 = 1 << 20
    private static let maxConnections = 16
    private static let maxTries = 4

    /// Returns a file in the temp directory (the caller owns it) and a response to take the file name from.
    public static func run(_ url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = maxConnections   // macOS defaults to 6
        cfg.timeoutIntervalForRequest = 30
        let session: DownloadTransport = Transport.curl ?? SegmentSession(cfg)
        defer { session.invalidate() }

        do {
            if let (total, response) = await probeRanges(url) {
                do { return (try await segmented(url, total, session, onProgress), response) }
                catch is CancellationError { throw CancellationError() }
                catch let e as URLError where e.code == .cancelled { throw CancellationError() }
                catch {
                    // Per-segment retries are exhausted (flaky transport, server throttling parallel
                    // connections): fall back to one plain stream rather than failing the whole download.
                    if Task.isCancelled { throw CancellationError() }
                    return try await single(url, session, onProgress)
                }
            }
            return try await single(url, session, onProgress)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        }
    }

    /// The name a server wants for the file: Content-Disposition, else the URL's last path component.
    /// (`URLResponse.suggestedFilename` is unreliable off Apple platforms.)
    public static func fileName(for response: URLResponse, url: URL) -> String {
        if let h = response as? HTTPURLResponse, let cd = h.value(forHTTPHeaderField: "Content-Disposition") {
            // filename*=UTF-8''percent%20encoded   or   filename="plain.ext"
            if let r = cd.range(of: "filename*=", options: .caseInsensitive) {
                let v = cd[r.upperBound...].split(separator: ";").first.map(String.init) ?? ""
                if let q = v.range(of: "''"), let n = String(v[q.upperBound...]).removingPercentEncoding, !n.isEmpty { return n }
            }
            if let r = cd.range(of: "filename=", options: .caseInsensitive) {
                let v = cd[r.upperBound...].split(separator: ";").first.map(String.init) ?? ""
                let n = v.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                if !n.isEmpty { return n }
            }
        }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? "download") : last
    }

    // MARK: Plan

    /// Total size if the server honours byte ranges and the file is worth splitting.
    private static func probeRanges(_ url: URL) async -> (Int64, HTTPURLResponse)? {
        guard let (_, r) = try? await HTTP.fetch(request(url, range: "bytes=0-0")),
              let h = r as? HTTPURLResponse, h.statusCode == 206,
              let total = h.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ Int64($0) }),
              total >= 2 * minSegment else { return nil }
        return (total, h)
    }

    private static func request(_ url: URL, range: String? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(Tools.userAgent, forHTTPHeaderField: "User-Agent")
        if let range { r.setValue(range, forHTTPHeaderField: "Range") }
        return r
    }

    // MARK: Single stream

    private static func single(_ url: URL, _ session: DownloadTransport,
                               _ onProgress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        let (file, resp) = try await session.download(request(url)) { written, expected in
            if expected > 0 { onProgress(Double(written) / Double(expected)) }
        }
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            try? FileManager.default.removeItem(at: file)
            throw NSError(domain: "Pea", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server said \(h.statusCode)"])
        }
        return (file, resp)
    }

    // MARK: Segments

    private static func segmented(_ url: URL, _ total: Int64, _ session: DownloadTransport,
                                  _ onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let count = Int(min(Int64(maxConnections), max(2, total / minSegment)))
        let size = (total + Int64(count) - 1) / Int64(count)
        let progress = SegmentProgress(total: total, segments: count, report: onProgress)
        let parts = PartStore()
        defer { parts.removeAll() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let start = Int64(i) * size, end = min(total - 1, start + size - 1)
                guard start <= end else { continue }
                group.addTask {
                    let part = try await fetchSegment(url, start, end, session) { progress.update(i, $0) }
                    parts.add(i, part)
                }
            }
            try await group.waitForAll()
        }
        return try stitch(parts.ordered())
    }

    private static func fetchSegment(_ url: URL, _ start: Int64, _ end: Int64, _ session: DownloadTransport,
                                     _ onBytes: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<maxTries {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(1_000_000_000) << UInt64(attempt - 1)) }   // 1s, 2s, 4s
            do {
                onBytes(0)
                let (file, resp) = try await session.download(request(url, range: "bytes=\(start)-\(end)")) { written, _ in onBytes(written) }
                let got = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
                guard (resp as? HTTPURLResponse)?.statusCode == 206, got == end - start + 1 else {
                    try? FileManager.default.removeItem(at: file)
                    throw URLError(.badServerResponse)
                }
                return file
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func stitch(_ parts: [URL]) throws -> URL {
        let out = tempFile()
        _ = FileManager.default.createFile(atPath: out.path, contents: nil)
        do {
            let w = try FileHandle(forWritingTo: out)
            defer { try? w.close() }
            for part in parts {
                let r = try FileHandle(forReadingFrom: part)
                defer { try? r.close() }
                while let chunk = try r.read(upToCount: 4 << 20), !chunk.isEmpty { try w.write(contentsOf: chunk) }
            }
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    static func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pea-" + UUID().uuidString)
    }
}

/// A URLSession whose downloads are driven through the delegate (portable: no KVO, no async download API).
/// Each task's result lands in a file we own; cancelling the awaiting Task cancels the transfer.
final class SegmentSession: NSObject, URLSessionDownloadDelegate, DownloadTransport, @unchecked Sendable {
    private struct Entry {
        var cont: CheckedContinuation<(URL, URLResponse), Error>
        var onBytes: @Sendable (Int64, Int64) -> Void
        var file: URL?
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var session: URLSession!

    init(_ cfg: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    func download(_ request: URLRequest,
                  onBytes: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void) async throws -> (URL, URLResponse) {
        let box = HTTP.TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                let t = session.downloadTask(with: request)
                lock.withLock { entries[t.taskIdentifier] = Entry(cont: c, onBytes: onBytes) }
                box.set(t)
                t.resume()
            }
        } onCancel: { box.cancel() }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        let handler = lock.withLock { entries[t.taskIdentifier]?.onBytes }
        handler?(w, e)
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns, so move it right away.
        let keep = HTTPDownload.tempFile()
        guard (try? FileManager.default.moveItem(at: location, to: keep)) != nil else { return }
        lock.withLock { entries[t.taskIdentifier]?.file = keep }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ entries.removeValue(forKey: t.taskIdentifier) }) else { return }
        if let error {
            if let f = entry.file { try? FileManager.default.removeItem(at: f) }
            entry.cont.resume(throwing: error)
        } else if let file = entry.file, let resp = t.response {
            entry.cont.resume(returning: (file, resp))
        } else {
            entry.cont.resume(throwing: URLError(.cannotCreateFile))
        }
    }
}

private final class SegmentProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Int64]
    private let total: Int64
    private let report: @Sendable (Double) -> Void

    init(total: Int64, segments: Int, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.report = report
        received = Array(repeating: 0, count: segments)
    }

    func update(_ segment: Int, _ bytes: Int64) {
        let sum: Int64 = lock.withLock { received[segment] = bytes; return received.reduce(0, +) }
        report(Double(sum) / Double(total))
    }
}

private final class PartStore: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Int: URL] = [:]

    func add(_ i: Int, _ url: URL) { lock.withLock { parts[i] = url } }
    func ordered() -> [URL] { lock.withLock { parts.sorted { $0.key < $1.key }.map(\.value) } }
    func removeAll() { lock.withLock { parts.values.forEach { try? FileManager.default.removeItem(at: $0) }; parts = [:] } }
}
