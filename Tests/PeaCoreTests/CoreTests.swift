import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PeaCore

final class CoreTests: XCTestCase {
    func testFirstLinkNeedsExplicitScheme() {
        XCTAssertNil(Model.firstLink(in: "axcoresettingsstore.org is not a link"))
        XCTAssertEqual(Model.firstLink(in: "watch https://youtu.be/abc123, it's great")?.absoluteString, "https://youtu.be/abc123")
        XCTAssertEqual(Model.firstLink(in: "(https://example.com/a.zip)")?.absoluteString, "https://example.com/a.zip")
    }

    func testSources() {
        XCTAssertTrue(Source.of(URL(string: "https://open.spotify.com/track/1")!).audioOnly)
        XCTAssertEqual(Source.of(URL(string: "https://www.youtube.com/watch?v=1")!).name, "YouTube")
        XCTAssertFalse(Source.of(URL(string: "https://example.com/x")!).isKnown)
    }

    func testAudioArguments() {
        let job = Job(target: "https://x", output: "o.%(ext)s", kind: .audio, quality: .high, format: .mp3)
        let a = YtDlp.arguments(job, temp: "/tmp/t")
        XCTAssertTrue(a.contains("--embed-thumbnail"))
        XCTAssertEqual(a[a.firstIndex(of: "--audio-quality")! + 1], "192K")
        let wav = YtDlp.arguments(Job(target: "u", output: "o", kind: .audio, quality: .high, format: .wav), temp: "/tmp/t")
        XCTAssertFalse(wav.contains("--embed-thumbnail"))
    }

    func testProgressTrackerWeighsVideoThenAudio() {
        var t = ProgressTracker(weightedVideo: true)
        XCTAssertEqual(t.feed("PROG 50 100 NA")!, 0.45, accuracy: 0.001)
        XCTAssertEqual(t.feed("PROG 100 100 NA")!, 0.9, accuracy: 0.001)
        XCTAssertEqual(t.feed("PROG 10 100 NA")!, 0.91, accuracy: 0.001)   // audio stream starts over
    }

    func testPaletteFromPixels() {
        // Two red pixels and one blue: red dominates but both survive the 12% cut-off.
        let px: [UInt8] = [220, 20, 20, 220, 20, 20, 20, 20, 220]
        XCTAssertEqual(Artwork.dominantColors(px).count, 2)
        XCTAssertTrue(Artwork.dominantColors([UInt8](repeating: 128, count: 48)).isEmpty)   // grey: no hue
    }
}

/// Real-network checks; run with PEA_NET_TESTS=1.
final class FileNameTests: XCTestCase {
    func testContentDispositionWins() {
        let url = URL(string: "https://x.test/dl?id=7")!
        func resp(_ cd: String) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Disposition": cd])!
        }
        XCTAssertEqual(HTTPDownload.fileName(for: resp("attachment; filename=\"a b.zip\""), url: url), "a b.zip")
        XCTAssertEqual(HTTPDownload.fileName(for: resp("attachment; filename*=UTF-8''caf%C3%A9.pdf"), url: url), "café.pdf")
        XCTAssertEqual(HTTPDownload.fileName(for: resp("inline"), url: URL(string: "https://x.test/a/b.mp3")!), "b.mp3")
    }
}

final class NetworkTests: XCTestCase {
    func testSegmentedDownloadMatchesKnownSize() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEA_NET_TESTS"] != nil)
        let url = URL(string: "https://proof.ovh.net/files/10Mb.dat")!
        let (file, resp) = try await HTTPDownload.run(url) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
        XCTAssertEqual(size, 10_485_760)
        XCTAssertEqual(HTTPDownload.fileName(for: resp, url: url), "10Mb.dat")
    }

    func testCancelStopsTheDownload() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEA_NET_TESTS"] != nil)
        let url = URL(string: "https://proof.ovh.net/files/10Mb.dat")!
        let task = Task { try await HTTPDownload.run(url) { _ in } }
        try await Task.sleep(nanoseconds: 800_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("should have been cancelled") }
        catch is CancellationError {}
        catch { XCTFail("expected cancellation, got \(error)") }
    }
}

final class MetaNetworkTests: XCTestCase {
    func testSpotifyMeta() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PEA_NET_TESTS"] != nil)
        let t0 = Date()
        let m = await Tools.fetchMeta(URL(string: "https://open.spotify.com/track/20I6sIOMTCkB6w7ryavxtO?si=abc")!)
        print("META", m.title ?? "nil", m.art?.data.count ?? -1, Date().timeIntervalSince(t0))
        XCTAssertEqual(m.title, "Call Me Maybe — Carly Rae Jepsen")
        XCTAssertNotNil(m.art)
    }
}
