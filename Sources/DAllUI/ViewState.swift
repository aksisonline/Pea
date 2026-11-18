import DAllCore
import Foundation

/// An immutable snapshot of what the window has to show, taken from `Model` (or forged by `Debug`).
/// The scene animates between snapshots; it never reads the model while drawing.
struct ViewState {
    enum Screen: Equatable {
        case idle, kind, quality(Kind), working, done(URL), failed(String), setup(String), ready
    }
    var screen: Screen = .idle
    var suggestion: Suggestion?            // the armed link (idle only)
    var hint: Suggestion?
    var art: Artwork?
    var badge: Source?
    var progress: Double?
    var setupStep: SetupStep?
    var setupDone = 0, setupTotal = 0
    var setupBusy = false
    var setupNote: String?
    var audioFormat = AudioFormat.opus

    var isIdle: Bool { screen == .idle }
    var armed: Bool { isIdle && suggestion != nil }
    var isSetup: Bool { if case .setup = screen { return true } else { return false } }
    var isReady: Bool { screen == .ready }
    var lit: Bool { armed || isSetup || isReady }
    var isWorking: Bool { screen == .working }
    var waving: Bool {
        switch screen {
        case .idle: return armed
        case .kind, .quality: return true
        default: return false
        }
    }
    var setupRing: (done: Int, total: Int)? {
        switch screen {
        case .setup: return (setupDone, max(1, setupTotal))
        case .ready: return (max(1, setupTotal), max(1, setupTotal))
        default: return nil
        }
    }

    /// Changes whenever the caption text would change, so it can cross-fade.
    var captionKey: String {
        switch screen {
        case .idle: return armed ? "armed|\(suggestion?.title ?? suggestion?.source.name ?? "")" : "idle"
        case .setup(let id): return "setup|\(id)|\(setupNote ?? "")"
        case .quality(let k): return k == .audio ? "audioPill" : "q"
        case .done(let u): return "done|\(u.path)"
        case .failed: return "failed"
        case .ready: return "ready"
        default: return "-"
        }
    }

    @MainActor
    init(_ m: Model) {
        audioFormat = m.audioFormat
        setupNote = m.setupNote
        setupBusy = m.setupBusy
        progress = m.progress
        switch m.phase {
        case .idle:
            screen = .idle
            suggestion = m.suggestion
            hint = m.hint
            art = m.suggestion?.art
            badge = m.suggestion?.source
        case .kind: screen = .kind; art = m.currentArt
        case .quality(_, let k): screen = .quality(k); art = m.currentArt
        case .working: screen = .working; art = m.currentArt; badge = m.currentSource
        case .done(let u): screen = .done(u)
        case .failed(let msg): screen = .failed(msg)
        case .ready: screen = .ready; setupTotal = m.setupSteps.count
        case .setup(let step):
            screen = .setup(step.id)
            setupStep = step
            setupTotal = m.setupSteps.count
            setupDone = m.setupSteps.firstIndex(of: step) ?? 0
        }
    }

    init() {}
}
