import Foundation

/// How a UI should animate a state change. The core never animates; a shell maps these to its own curves.
public enum Motion: Sendable { case snappy, gentle, quick }

/// App state: what the circle is showing, what's on the clipboard, and the running download.
/// UI-framework free: a shell observes it through `onChange` and animates through `animate`.
@MainActor
public final class Model {
    // MARK: Observable state (read-only to UIs)

    public private(set) var phase: Phase = .idle { didSet { onChange?() } }
    public private(set) var progress: Double? { didSet { onChange?() } }
    /// A fresh, downloadable link on the clipboard: lights the circle up.
    public private(set) var suggestion: Suggestion? { didSet { onChange?() } }
    /// Any link on the clipboard while idle, even one that was dismissed or never auto-detected.
    public private(set) var hint: Suggestion? { didSet { onChange?() } }
    public private(set) var currentSource: Source? { didSet { onChange?() } }
    public private(set) var currentArt: Artwork? { didSet { onChange?() } }
    /// Extra line under a setup step when it needs more from the user, and whether a step is working.
    public private(set) var setupNote: String? { didSet { onChange?() } }
    public private(set) var setupBusy = false { didSet { onChange?() } }
    public var audioFormat = AudioFormat(rawValue: AppSettings.store.string("audioFormat") ?? "") ?? .opus {
        didSet { AppSettings.store.set(audioFormat.rawValue, for: "audioFormat"); onChange?() }
    }

    /// Called after any state change.
    public var onChange: (() -> Void)?
    /// Wraps a state change so the UI can animate it.
    public var animate: (Motion, () -> Void) -> Void = { _, body in body() }

    private func anim(_ motion: Motion, _ body: () -> Void) { animate(motion, body) }

    public let services: PlatformServices
    public var setupSteps: [SetupStep] { services.setupSteps }

    // MARK: Internals

    private var generation = 0                   // bumped on every cancel; stale async work checks it
    private var work: Task<Void, Never>?
    private var ytdlp: YtDlpRun?
    private var currentURL: URL?
    private var monitor: Task<Void, Never>?

    private var lastToken = Int.min              // clipboard token we last parsed
    private var clipboardLink: URL?
    private var consumedToken = Int.min          // token whose link has been used or dismissed
    private var metaCache: [URL: Meta] = [:]
    private var waiting: [URL: [(Meta) -> Void]] = [:]   // callbacks for a metadata fetch in flight
    private var rejected: [URL: Date] = [:]      // links yt-dlp couldn't read; retried after a while

    nonisolated(unsafe) private static let linkRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#, options: [.caseInsensitive])

    public init(services: PlatformServices) {
        self.services = services
        if !AppSettings.store.bool("setupDone"), let first = services.setupSteps.first {
            phase = .setup(first)
            settleSetup()
        }
    }

    /// Starts watching the clipboard. Call once the UI is up.
    public func start() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshClipboard()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    // MARK: Clipboard

    /// The http(s) link on the clipboard; text is only re-read and re-parsed when the clipboard changes.
    private func currentClipboardLink() -> URL? {
        let token = services.clipboard.changeToken
        if token != lastToken {
            lastToken = token
            clipboardLink = services.clipboard.read().flatMap(Self.firstLink)
        }
        return clipboardLink
    }

    /// First-run setup, and the "Ready!" beat after it, own the screen: no input is taken meanwhile.
    private var isOnboarding: Bool {
        switch phase {
        case .setup, .ready: return true
        default: return false
        }
    }

    private var hasFreshLink: Bool { services.clipboard.changeToken != consumedToken }

    private func refreshClipboard() {
        if isOnboarding { return }          // no clipboard reads until setup has asked for access
        if case .working = phase { return }
        let link = currentClipboardLink()

        // Hover hint: any link, only while idle.
        var hinted: URL?
        if case .idle = phase { hinted = link }
        if hint?.url != hinted {
            hint = hinted.map { Suggestion(url: $0, title: metaCache[$0]?.title, art: metaCache[$0]?.art, source: Source.of($0)) }
            if let h = hint, h.source.isKnown { warmHint() }   // known services: have the peek ready
        }

        // Suggestion: a fresh link that's worth lighting up for.
        guard hasFreshLink, let link, !isRejected(link) else {
            if suggestion != nil { anim(.snappy) { suggestion = nil } }
            return
        }
        guard suggestion?.url != link else { return }
        let source = Source.of(link)
        if source.isKnown {
            anim(.snappy) { suggestion = Suggestion(url: link, title: nil, art: nil, source: source) }
            loadMeta(link) { [weak self] m in
                guard let self, suggestion?.url == link else { return }
                anim(.gentle) { self.suggestion?.title = m.title; self.suggestion?.art = m.art }
            }
        } else {
            // Unknown site: only light up once yt-dlp can actually read a title from it.
            loadMeta(link) { [weak self] m in
                guard let self, let title = m.title, hasFreshLink, clipboardLink == link else { return }
                if case .working = phase { return }
                anim(.snappy) { self.suggestion = Suggestion(url: link, title: title, art: m.art, source: source) }
            }
        }
    }

    private func isRejected(_ url: URL) -> Bool {
        guard let when = rejected[url] else { return false }
        if Date().timeIntervalSince(when) > 120 { rejected[url] = nil; return false }
        return true
    }

    /// Fetches a link's title + artwork once, then calls back on the main actor (immediately if cached).
    /// Several callers can wait on the same fetch.
    private func loadMeta(_ url: URL, then apply: @escaping (Meta) -> Void) {
        if let m = metaCache[url] { apply(m); return }
        guard !isRejected(url) else { return }
        if waiting[url] != nil { waiting[url]?.append(apply); return }
        waiting[url] = [apply]
        Task {
            let m = await Tools.fetchMeta(url)
            if m.title != nil { metaCache[url] = m } else { rejected[url] = Date() }
            let callbacks = waiting.removeValue(forKey: url) ?? []
            callbacks.forEach { $0(m) }
        }
    }

    /// Fetch artwork + title for the hinted link so the hover peek can use them.
    public func warmHint() {
        guard let h = hint, h.art == nil || h.title == nil else { return }
        loadMeta(h.url) { [weak self] m in
            guard let self, hint?.url == h.url else { return }
            anim(.quick) {
                if m.art != nil { self.hint?.art = m.art }
                if m.title != nil { self.hint?.title = m.title }
            }
        }
    }

    private func consumeClipboard() {
        consumedToken = services.clipboard.changeToken
        suggestion = nil
    }

    /// The first http(s) link in some text, without trailing punctuation.
    nonisolated public static func firstLink(in text: String) -> URL? {
        guard let re = linkRegex,
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        var s = String(text[r])
        while let last = s.last, ".,;:!?)]}".contains(last) { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    // MARK: Input

    public func paste() {
        guard let s = services.clipboard.read() else { return }
        accept(s)
    }

    public func accept(_ text: String) {
        if isOnboarding { return }
        guard let url = Self.firstLink(in: text) else {
            if case .working = phase { return }      // a stray paste must not clobber a running download
            anim(.quick) { phase = .failed("That’s not a link") }
            return
        }
        open(url)
    }

    /// Menu-bar popover just opened: if a fresh link is on the clipboard, jump straight into the choices.
    public func popoverOpened() {
        if isOnboarding { return }
        if case .working = phase { return }
        guard hasFreshLink, let link = currentClipboardLink(), !isRejected(link) else { return }
        open(link)
    }

    public func clickHero() {
        guard case .idle = phase, let s = suggestion else { return }
        open(s.url)
    }

    /// Start on a link: choose Video/Audio, choose quality, or (plain files) just download.
    public func open(_ url: URL) {
        if isOnboarding { return }
        cancelWork()
        // Carry over what we know before the clipboard bookkeeping clears it, so the next screen has no flash.
        let known = metaCache[url]?.art ?? suggestion?.art ?? hint?.art
        consumeClipboard()
        let source = Source.of(url)
        currentURL = url
        currentSource = source
        currentArt = known
        if known == nil {
            loadMeta(url) { [weak self] m in
                guard let self, currentURL == url, let art = m.art else { return }
                anim(.gentle) { self.currentArt = art }
            }
        }

        if source.isPinterest {
            // Images stay images, GIFs stay GIFs, videos stay videos: nothing to choose.
            let gen = generation
            anim(.snappy) { phase = .working }
            work = Task { await downloadPin(url, gen: gen) }
            return
        }
        if source.isKnown {
            anim(.snappy) { phase = source.audioOnly ? .quality(url, .audio) : .kind(url) }
            return
        }
        // Unknown site: a plain file downloads directly; an HTML page goes through yt-dlp.
        let gen = generation
        anim(.snappy) { phase = .working }
        work = Task {
            let isFile = await Tools.isDirectFile(url)
            guard gen == generation, !Task.isCancelled else { return }
            if isFile { await downloadFile(url, gen: gen) }
            else { anim(.snappy) { phase = .kind(url) } }
        }
    }

    public func choose(_ kind: Kind) {
        guard case .kind(let url) = phase else { return }
        anim(.snappy) { phase = .quality(url, kind) }
    }

    public func choose(_ quality: Quality) {
        guard case .quality(let url, let kind) = phase else { return }
        cancelWork()
        let gen = generation
        anim(.snappy) { phase = .working }
        work = Task { await downloadMedia(url, kind: kind, quality: quality, gen: gen) }
    }

    public func reset() {
        if isOnboarding { return }
        cancelWork()
        consumeClipboard()
        anim(.snappy) { phase = .idle }
    }

    // MARK: Setup

    /// If the current step is already satisfied, move past it.
    private func settleSetup() {
        if case .setup(let step) = phase, services.isSatisfied(step) { advanceSetup() }
    }

    public func skipSetup() { finishSetup(celebrate: false) }

    private func finishSetup(celebrate: Bool) {
        AppSettings.store.set(true, for: "setupDone")
        setupNote = nil
        consumeClipboard()                        // whatever was copied before setup isn't a fresh link
        guard celebrate else { anim(.snappy) { phase = .idle }; return }
        anim(.snappy) { phase = .ready }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if case .ready = phase { anim(.gentle) { phase = .idle } }
        }
    }

    private func advanceSetup() {
        guard case .setup(let step) = phase else { return }
        setupNote = nil
        let steps = services.setupSteps
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { finishSetup(celebrate: true); return }
        anim(.snappy) { phase = .setup(steps[i + 1]) }
        settleSetup()
    }

    /// The circle's action for the current setup step.
    public func performSetupStep() {
        guard case .setup(let step) = phase, !setupBusy else { return }
        let again = setupNote != nil
        setupBusy = true
        Task {
            let result = await services.perform(step, again: again)
            setupBusy = false
            switch result {
            case .done: advanceSetup()
            case .needsAction(let note), .failed(let note): setupNote = note
            }
        }
    }

    // MARK: Downloads

    private func cancelWork() {
        generation += 1
        work?.cancel()
        work = nil
        ytdlp?.cancel()
        ytdlp = nil
        progress = nil
    }

    private func report(_ p: Double, gen: Int) {
        guard gen == generation else { return }
        progress = max(progress ?? 0, min(p, 1))
    }

    private func succeed(_ file: URL) {
        progress = nil
        anim(.snappy) { phase = .done(file) }
    }

    private func fail(_ message: String?) {
        progress = nil
        var msg = (message ?? "Something went wrong").replacingOccurrences(of: "ERROR: ", with: "")
        if msg.count > 90 { msg = String(msg.prefix(90)) + "…" }
        anim(.snappy) { phase = .failed(msg) }
    }

    /// Plain file over HTTP(S), several connections at once.
    private func downloadFile(_ url: URL, gen: Int) async {
        do {
            let (tmp, resp) = try await HTTPDownload.run(url) { [weak self] p in
                Task { @MainActor in self?.report(p, gen: gen) }
            }
            guard gen == generation, !Task.isCancelled else { try? FileManager.default.removeItem(at: tmp); return }
            let dir = Platform.downloadsDirectory
            let name = FileNames.sanitize(HTTPDownload.fileName(for: resp, url: url), fallback: url.host ?? "download",
                                          dirLength: dir.path.count)
            let dest = FileNames.unique(name, in: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileNames.move(tmp, to: dest)
            succeed(dest)
        } catch is CancellationError {
        } catch {
            guard gen == generation else { return }
            fail((error as NSError).localizedDescription)
        }
    }

    /// Pinterest: video and GIF pins come from yt-dlp as they are; plain image pins are read from the page.
    private func downloadPin(_ url: URL, gen: Int) async {
        let run = YtDlpRun()
        ytdlp = run
        let out = await run.run(Job(target: url.absoluteString, output: "%(title).120B.%(ext)s", kind: .video,
                                    quality: .original, format: audioFormat, original: true)) { [weak self] p in
            Task { @MainActor in self?.report(p, gen: gen) }
        }
        guard gen == generation, !Task.isCancelled else { return }
        ytdlp = nil
        if out.status == 0, let path = out.path, FileManager.default.fileExists(atPath: path) {
            succeed(URL(fileURLWithPath: path)); return
        }
        if let image = await Tools.pinterestImage(url) {
            guard gen == generation, !Task.isCancelled else { return }
            await downloadFile(image, gen: gen)
        } else if gen == generation {
            fail(out.error ?? "Couldn’t find anything to download on this pin")
        }
    }

    /// Video/audio via yt-dlp. Spotify is resolved to a YouTube search first.
    private func downloadMedia(_ url: URL, kind: Kind, quality: Quality, gen: Int, original: Bool = false) async {
        var job = Job(target: url.absoluteString, output: "%(title).120B.%(ext)s",
                      kind: kind, quality: quality, format: audioFormat, original: original)
        if Source.of(url).isSpotify {
            guard let info = await Tools.spotifyInfo(url) else {
                if gen == generation { fail("Only Spotify tracks are supported") }
                return
            }
            var name = [info.artist, info.title].filter { !$0.isEmpty }.joined(separator: " - ")
            name = FileNames.sanitize(name, fallback: "track", windows: false)
            name = name.replacingOccurrences(of: "%", with: "%%")        // yt-dlp output template escape
            job.target = "ytsearch1:\(info.artist) \(info.title) audio"
            job.output = name + ".%(ext)s"
            job.attempt = 1                                              // the plain client 403s on these
        }
        var firstError: String?
        while gen == generation, !Task.isCancelled {
            let run = YtDlpRun()
            ytdlp = run
            let out = await run.run(job) { [weak self] p in Task { @MainActor in self?.report(p, gen: gen) } }
            guard gen == generation else { return }
            ytdlp = nil
            if out.status == 0, let path = out.path, FileManager.default.fileExists(atPath: path) {
                succeed(URL(fileURLWithPath: path)); return
            }
            firstError = firstError ?? out.error
            // Any failure may be one client's quirk (403, bot check, missing format), so try the next client.
            if !job.original, job.attempt + 1 < YtDlp.clients.count {
                job.attempt += 1; progress = nil; continue
            }
            fail(firstError ?? out.error); return
        }
    }
}
