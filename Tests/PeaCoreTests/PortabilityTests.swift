import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PeaCore

/// Platform-neutral tests for everything the Windows port relies on; they run on macOS, Linux and Windows.
final class WindowsCommandLineTests: XCTestCase {
    func testQuoteRoundTripsThroughTheCRuntimeSplitter() {
        let ppa = "ThumbnailsConvertor+ffmpeg_o:-vf crop=\"'min(iw,ih)':'min(iw,ih)'\""
        let nasty = [
            ppa, "%(title).120B.%(ext)s", "download:PROG %(progress.downloaded_bytes)s %(progress.total_bytes)s",
            "", " ", "plain", "has space", "tab\there", "quote\"inside", "\"", "\"\"", "\\", "\\\\", "trail\\",
            "trail space\\", "trail\\\\", "a\\\"b", "a\\\\\"b", "C:\\Users\\Jo Smith\\Downloads\\", "C:\\a b\\c\\",
            "temp:C:\\Users\\x\\AppData\\Local\\Temp\\pea-1234", "https://x.test/a?b=1&c=2|3^4", "naïve — 日本語 🎵",
            "min(iw,ih)", "it's", "'single'", "ytsearch1:Artist Title audio",
        ]
        let line = WindowsCommandLine.join(nasty)
        XCTAssertEqual(WindowsCommandLine.split(line), nasty)
        for a in nasty { XCTAssertEqual(WindowsCommandLine.split(WindowsCommandLine.quote(a)), [a], "arg: \(a)") }
    }

    func testQuoteLeavesSafeArgsAlone() {
        XCTAssertEqual(WindowsCommandLine.quote("--no-playlist"), "--no-playlist")
        XCTAssertEqual(WindowsCommandLine.quote("C:\\x\\y.exe"), "C:\\x\\y.exe")
        XCTAssertEqual(WindowsCommandLine.quote("a b"), "\"a b\"")
        XCTAssertEqual(WindowsCommandLine.quote("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(WindowsCommandLine.quote("dir \\"), "\"dir \\\\\"")
        XCTAssertEqual(WindowsCommandLine.quote(""), "\"\"")
    }

    func testEnvironmentBlock() {
        let b = WindowsCommandLine.environmentBlock(["b": "2", "A": "1", "Path": "C:\\x;D:\\y"])
        XCTAssertEqual(String(decoding: b, as: UTF16.self).replacingOccurrences(of: "\0", with: "|"), "A=1|b=2|Path=C:\\x;D:\\y||")
        XCTAssertEqual(WindowsCommandLine.environmentBlock([:]), [0, 0])
    }
}

final class YtDlpArgumentTests: XCTestCase {
    private let job = Job(target: "https://x.test/v", output: "%(title).120B.%(ext)s", kind: .audio, quality: .original, format: .opus)

    func testWindowsGetsUTF8AndFfmpegLocation() {
        let w = YtDlp.arguments(job, temp: "C:\\T\\pea-1", downloads: "C:\\Users\\Jo\\Downloads", windows: true,
                                ffmpegLocation: "C:\\ff\\bin")
        XCTAssertEqual(w[w.firstIndex(of: "--encoding")! + 1], "utf-8")
        XCTAssertEqual(w[w.firstIndex(of: "--ffmpeg-location")! + 1], "C:\\ff\\bin")
        XCTAssertEqual(w[w.firstIndex(of: "-P")! + 1], "C:\\Users\\Jo\\Downloads")
        XCTAssertTrue(w.contains("temp:C:\\T\\pea-1"))
        XCTAssertEqual(w.last, "https://x.test/v")
        let p = YtDlp.arguments(job, temp: "/t", downloads: "/d", windows: false, ffmpegLocation: "/x")
        XCTAssertFalse(p.contains("--encoding"))
        XCTAssertFalse(p.contains("--ffmpeg-location"))
    }

    func testPPAValueSurvivesTheCreateProcessRoundTrip() {
        let w = YtDlp.arguments(job, temp: "C:\\T", downloads: "C:\\D", windows: true)
        let ppa = w[w.firstIndex(of: "--ppa")! + 1]
        XCTAssertTrue(ppa.contains("\"") && ppa.contains("'") && ppa.contains("("))
        XCTAssertEqual(WindowsCommandLine.split(WindowsCommandLine.join(["yt-dlp.exe"] + w)), ["yt-dlp.exe"] + w)
    }

    func testPathLines() {
        XCTAssertTrue(YtDlpRun.looksLikePath("C:\\Users\\Jo\\Downloads\\a.mp3"))
        XCTAssertTrue(YtDlpRun.looksLikePath("d:/x/a.mp3"))
        XCTAssertTrue(YtDlpRun.looksLikePath("\\\\nas\\share\\a.mp3"))
        XCTAssertTrue(YtDlpRun.looksLikePath("/Users/jo/a.mp3"))
        XCTAssertFalse(YtDlpRun.looksLikePath("PROG 1 2 3"))
        XCTAssertFalse(YtDlpRun.looksLikePath("ERROR: x"))
        XCTAssertFalse(YtDlpRun.looksLikePath("C:"))
    }

    func testLineStreamSplitsAcrossChunksAndCRLF() async {
        let chunks = ["PROG 1 10 N", "A\r\nPROG 2 10 NA\r", "\nC:\\x\\é", ".mp3\n", "tail"]
        let q = ChunkQueue(chunks.map { Data($0.utf8) })
        var got: [String] = []
        for await l in LineStream(read: { q.next() }).lines { got.append(l) }
        XCTAssertEqual(got, ["PROG 1 10 NA", "PROG 2 10 NA", "C:\\x\\é.mp3", "tail"])
    }
}

private final class ChunkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data]
    init(_ items: [Data]) { self.items = items }
    func next() -> Data { lock.withLock { items.isEmpty ? Data() : items.removeFirst() } }
}

final class ToolLookupTests: XCTestCase {
    func testWindowsAppendsExeAndUsesBackslashes() {
        var seen: [String] = []
        let r = Tools.resolve("yt-dlp", dirs: ["C:\\a", "C:\\b\\", ""], windows: true) { seen.append($0); return $0 == "C:\\b\\yt-dlp.exe" }
        XCTAssertEqual(r, "C:\\b\\yt-dlp.exe")
        XCTAssertEqual(seen, ["C:\\a\\yt-dlp.exe", "C:\\b\\yt-dlp.exe"])
        XCTAssertEqual(Tools.resolve("ffmpeg.exe", dirs: ["C:\\a"], windows: true) { $0 == "C:\\a\\ffmpeg.exe" }, "C:\\a\\ffmpeg.exe")
        XCTAssertEqual(Tools.resolve("curl", dirs: ["/usr/bin", "/bin/"], windows: false) { $0 == "/bin/curl" }, "/bin/curl")
    }

    func testPathVariableIsCaseInsensitiveOnWindowsAndQuoted() {
        let env = ["Path": "C:\\a;\"C:\\Program Files\\b\";;  C:\\c "]
        XCTAssertEqual(Tools.pathEntries(env, windows: true), ["C:\\a", "C:\\Program Files\\b", "C:\\c"])
        XCTAssertEqual(Tools.pathEntries(env, windows: false), [])
        XCTAssertEqual(Tools.pathEntries(["PATH": "/a:/b"], windows: false), ["/a", "/b"])
    }

    func testChildEnvironment() {
        let w = Tools.environment(from: ["Path": "C:\\sys"], extra: ["C:\\x"], windows: true)
        XCTAssertEqual(w["Path"], "C:\\x;C:\\sys")
        XCTAssertNil(w["PATH"])
        XCTAssertEqual(w["PYTHONUTF8"], "1")
        XCTAssertEqual(w["PYTHONIOENCODING"], "utf-8")
        let p = Tools.environment(from: ["PATH": "/usr/bin"], extra: ["/opt/x"], windows: false)
        XCTAssertEqual(p["PATH"], "/opt/x:/usr/bin")
        XCTAssertNil(p["PYTHONUTF8"])
    }

    func testWingetPackageDirs() {
        let tree = ["R": ["yt-dlp.yt-dlp_Microsoft.Winget.Source_8wekyb3d8bbwe", "Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe", "Other.App_x"],
                    "R\\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe": ["ffmpeg-7.1-full_build"]]
        let dirs = Platform.expandPackageDirs(root: "R") { tree[$0] ?? [] }
        XCTAssertTrue(dirs.contains("R\\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\\ffmpeg-7.1-full_build\\bin"))
        XCTAssertTrue(dirs.contains("R\\yt-dlp.yt-dlp_Microsoft.Winget.Source_8wekyb3d8bbwe"))
        XCTAssertFalse(dirs.contains { $0.contains("Other") })
    }

    func testNativePath() {
        XCTAssertEqual(Platform.windowsPath(fromURLPath: "/C:/Users/Jo Smith/Downloads"), "C:\\Users\\Jo Smith\\Downloads")
        XCTAssertEqual(Platform.windowsPath(fromURLPath: "C:/Users/x"), "C:\\Users\\x")
        XCTAssertEqual(Platform.windowsPath(fromURLPath: "//nas/share/x"), "\\\\nas\\share\\x")
        XCTAssertEqual(Platform.nativePath(URL(fileURLWithPath: "/tmp/x"), windows: false), "/tmp/x")
    }
}

final class FileNameSanitizingTests: XCTestCase {
    func testForbiddenCharactersEverywhere() {
        XCTAssertEqual(FileNames.sanitize("a/b\\c:d*e?f\"g<h>i|j.txt", windows: false), "a-b-c-d-e-f-g-h-i-j.txt")
        XCTAssertEqual(FileNames.sanitize("", fallback: "host", windows: false), "host")
        XCTAssertEqual(FileNames.sanitize("///", fallback: "host", windows: false), "host")
        XCTAssertEqual(FileNames.sanitize("a\u{0}b\nc.txt", windows: false), "a-b-c.txt")
    }

    func testWindowsReservedNamesAndTrailingDots() {
        for n in ["CON", "con.txt", "NUL", "aux.tar.gz", "COM1", "lpt9.log", "Prn "] {
            XCTAssertTrue(FileNames.sanitize(n, windows: true).hasPrefix("_"), n)
        }
        XCTAssertEqual(FileNames.sanitize("console.txt", windows: true), "console.txt")
        XCTAssertEqual(FileNames.sanitize("COM10.txt", windows: true), "COM10.txt")
        XCTAssertEqual(FileNames.sanitize("report. . ", windows: true), "report")
        XCTAssertEqual(FileNames.sanitize("a.txt.", windows: true), "a.txt")
        XCTAssertEqual(FileNames.sanitize("CON", windows: false), "CON")
    }

    func testLengthLimitsKeepTheExtension() {
        let long = String(repeating: "x", count: 400) + ".mp4"
        let posix = FileNames.sanitize(long, windows: false)
        XCTAssertLessThanOrEqual(posix.utf8.count, 255 - 12)
        XCTAssertTrue(posix.hasSuffix(".mp4"))
        let dir = "C:\\Users\\" + String(repeating: "u", count: 100) + "\\Downloads"
        let win = FileNames.sanitize(long, dirLength: dir.count, windows: true)
        XCTAssertLessThanOrEqual(dir.count + 1 + win.count + 6, 260)
        XCTAssertTrue(win.hasSuffix(".mp4"))
        let cjk = FileNames.sanitize(String(repeating: "日", count: 200) + ".mp3", windows: false)
        XCTAssertLessThanOrEqual(cjk.utf8.count, 255)
    }

    func testUniqueAndMove() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pea-test-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        try Data("hi".utf8).write(to: a)
        let u = FileNames.unique("a.txt", in: dir)
        XCTAssertEqual(u.lastPathComponent, "a (1).txt")
        let src = dir.appendingPathComponent("src.bin")
        try Data("x".utf8).write(to: src)
        try FileNames.move(src, to: u)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try Data(contentsOf: u), Data("x".utf8))
    }
}

final class SettingsTests: XCTestCase {
    func testJSONStorePersistsAndSurvivesCorruption() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pea-test-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/settings.json")
        let s = JSONFileSettings(url: url)
        XCTAssertFalse(s.bool("setupDone"))
        s.set(true, for: "setupDone"); s.set("MP3", for: "audioFormat")
        let again = JSONFileSettings(url: url)
        XCTAssertTrue(again.bool("setupDone"))
        XCTAssertEqual(again.string("audioFormat"), "MP3")
        again.set(nil, for: "audioFormat")
        XCTAssertNil(JSONFileSettings(url: url).string("audioFormat"))
        try Data("{not json".utf8).write(to: url)
        XCTAssertFalse(JSONFileSettings(url: url).bool("setupDone"))
    }
}

final class TransportTests: XCTestCase {
    func testParsesTheFinalResponseAfterRedirects() {
        let text = "HTTP/1.1 302 Found\r\nLocation: https://cdn.test/f\r\n\r\nHTTP/2 206 \r\ncontent-type: video/mp4\r\ncontent-range: bytes 0-0/12345\r\ncontent-length: 1\r\n\r\n"
        let r = CurlTransport.parseHeaders(text, url: URL(string: "https://x.test/f")!)
        XCTAssertEqual(r?.statusCode, 206)
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Content-Range"), "bytes 0-0/12345")
        XCTAssertEqual(r?.mimeType, "video/mp4")
        XCTAssertNil(CurlTransport.parseHeaders("", url: URL(string: "https://x.test")!))
    }

    func testCurlArgumentsAreVerbatim() {
        var req = URLRequest(url: URL(string: "https://x.test/a b?x=[1]")!)
        req.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let a = CurlTransport.arguments(req, body: "/tmp/b", headers: "/tmp/h", head: false, totalTimeout: 12)
        XCTAssertTrue(a.contains("--globoff"))
        XCTAssertEqual(a[a.firstIndex(of: "--header")! + 1], "Range: bytes=0-99")
        XCTAssertEqual(a[a.firstIndex(of: "--max-time")! + 1], "12")
        XCTAssertEqual(a.last, req.url!.absoluteString)
        XCTAssertEqual(CurlTransport.urlErrorCode(forCurlExit: 28), .timedOut)
    }
}

final class TrayGlyphTests: XCTestCase {
    func testGlyphShape() {
        let lit = TrayGlyph.bgra(size: 16, lit: true), ring = TrayGlyph.bgra(size: 16, lit: false)
        XCTAssertEqual(lit.count, 16 * 16 * 4)
        XCTAssertEqual(lit[(8 * 16 + 8) * 4 + 3], 255)    // centre filled when lit
        XCTAssertEqual(ring[(8 * 16 + 8) * 4 + 3], 0)     // hollow when idle
        XCTAssertEqual(lit[3], 0)                         // corner transparent
    }
}

/// Local-server check of the transports (no internet): PEA_TEST_URL=http://127.0.0.1:8765/big.bin PEA_TEST_SIZE=<bytes>,
/// served by a range-capable server. Run once per transport with PEA_TRANSPORT=curl and =urlsession.
final class LocalTransportTests: XCTestCase {
    func testSegmentedDownloadAgainstLocalServer() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PEA_TEST_URL"] != nil && env["PEA_TEST_SIZE"] != nil)
        let url = URL(string: env["PEA_TEST_URL"]!)!
        let (file, resp) = try await HTTPDownload.run(url) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
        XCTAssertEqual(size, Int(env["PEA_TEST_SIZE"]!))
        XCTAssertEqual(HTTPDownload.fileName(for: resp, url: url), url.lastPathComponent)
        let isFile = await Tools.isDirectFile(url)
        XCTAssertTrue(isFile)
    }
}
