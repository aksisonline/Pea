import AppKit
import DAllCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    private func toggleMode() {
        if Settings.menuBarMode {
            Settings.menuBarMode = false
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } else {
            Settings.menuBarMode = true
            NSApp.windows
                .filter { !($0 is NSPanel) && $0.styleMask.contains(.titled) }
                .forEach { $0.close() }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.155, green: 0.16, blue: 0.158).ignoresSafeArea()
            VStack(spacing: 8) {
                Hero()
                Caption()
            }
            .padding(.top, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            ModeToggle { toggleMode() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(10)

            if case .setup = model.phase {
                Button("Skip") { model.skipSetup() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(14)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            if Settings.menuBarMode, n.object is NSPanel { model.popoverOpened() }
        }
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.accept(url.absoluteString) } }
                }
            } else {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    if let s { Task { @MainActor in model.accept(s) } }
                }
            }
            return true
        }
    }
}

// MARK: Hero circle — everything lives inside it

struct Hero: View {
    @EnvironmentObject var model: Model
    @State private var hover = false
    @State private var expansion: Suggestion?     // the link whose circle is growing to fill ours
    @State private var grown = false

    private var showHint: Bool { isIdle && !armed && model.hint != nil && hover && expansion == nil }

    /// Click on the hover hint: its circle grows to fill ours, then the next screen takes over.
    /// The grown circle stays underneath until that screen has settled, so nothing flashes in between.
    private func expandHint() {
        guard let h = model.hint else { return }
        expansion = h
        grown = false
        DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.38)) { grown = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            model.open(h.url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeOut(duration: 0.3)) { expansion = nil }
            }
        }
    }

    private var isIdle: Bool { if case .idle = model.phase { return true } else { return false } }
    private var armed: Bool { isIdle && model.suggestion != nil }
    private var isSetup: Bool { if case .setup = model.phase { return true } else { return false } }
    private var isReady: Bool { if case .ready = model.phase { return true } else { return false } }
    /// Accent-filled: the thing to click (armed link, setup step) or the finished-setup moment.
    private var lit: Bool { armed || isSetup || isReady }
    private var palette: [Color] { art?.colors ?? [.accentColor, Color.accentColor.opacity(0.6)] }
    /// Ring turns while there's a link to act on (armed, or choosing what to download).
    private var waving: Bool {
        switch model.phase {
        case .idle: return armed
        case .kind, .quality: return true
        default: return false
        }
    }
    private var setupSteps: (done: Int, total: Int)? {
        let total = model.setupSteps.count
        switch model.phase {
        case .setup(let step): return (model.setupSteps.firstIndex(of: step) ?? 0, total)
        case .ready: return (total, total)
        default: return nil
        }
    }
    private var isWorking: Bool { if case .working = model.phase { return true } else { return false } }
    private var art: Artwork? {
        switch model.phase {
        case .idle: return model.suggestion?.art
        case .kind, .quality, .working: return model.currentArt
        default: return nil
        }
    }
    private var badge: Source? {
        if armed { return model.suggestion?.source }
        if case .working = model.phase { return model.currentSource }
        return nil
    }

    var body: some View {
        ZStack {
            DotRing(palette: palette, waving: waving, working: isWorking, progress: model.progress, steps: setupSteps)
                .frame(width: 172, height: 172)

            Circle()
                .fill(lit ? Color.accentColor : Color(white: 0.27))
                .frame(width: 142, height: 142)
                .scaleEffect(lit && hover ? 1.04 : 1)

            if let art {
                GlassArt(image: art.nsImage)
                    .frame(width: 142, height: 142)
                    .scaleEffect(armed && hover ? 1.04 : 1)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if let h = expansion {
                Group {
                    if let a = h.art { GlassArt(image: a.nsImage) } else { Circle().fill(Color.accentColor) }
                }
                .frame(width: 142, height: 142)
                .scaleEffect(grown ? 1 : 0.42)
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            switch model.phase {
            case .working:
                Text(model.progress.map { "\(Int($0 * 100))" } ?? "")
                    .font(.system(size: 30, weight: .light).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            case .done(let url):
                DragFile(url: url) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.reset() }
                }
                .frame(width: 92, height: 92)
                .help("Drag to move")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .failed(let msg):
                Image(systemName: "exclamationmark")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
                    .help(msg)
            case .kind:
                Stack {
                    Option("Video") { model.choose(.video) }
                    Option("Audio") { model.choose(.audio) }
                }
            case .quality:
                Stack {
                    ForEach(Quality.allCases, id: \.self) { q in
                        Option(q.rawValue) { model.choose(q) }
                    }
                }
            case .ready:
                ReadyMark()
            case .setup(let step):
                Stack {
                    Image(systemName: step.symbol)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white)
                    Text(model.setupBusy ? "Working…" : "Click to \(step.action.lowercased())")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 4)
                }
            case .idle:
                ArrowDown()
                    .stroke(armed ? Color.white : Color(white: 0.58), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 34, height: 44)
                    .opacity(showHint || expansion != nil ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: showHint)
            }

            if showHint, let h = model.hint {
                if let t = h.title {
                    CircularText(text: t)
                        .frame(width: 172, height: 172)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                HintBubble(hint: h)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }

            if let badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(armed ? Color.accentColor : Color(white: 0.8))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(armed ? Color.white : Color(white: 0.2)))
                    .offset(x: 50, y: 50)
                    .help(badge.name)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 172, height: 172)
        .contentShape(Circle())
        .onHover { inside in
            hover = inside
            if inside { model.warmHint() }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: showHint)
        // A SwiftUI gesture over the circle makes the hosting view swallow mouse-downs, which
        // would starve the drag source. Only listen for taps while idle.
        .gesture(TapGesture().onEnded {
            if armed { model.clickHero() }
            else if isSetup { model.performSetupStep() }
            else if showHint { expandHint() }
        }, including: isIdle || isSetup ? .all : .subviews)
        .animation(.snappy, value: hover)
    }
}

struct ModeToggle: View {
    @AppStorage("menuBarMode") private var menuBarMode = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: menuBarMode ? "macwindow" : "menubar.rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? Color.white : Color(white: 0.5))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(menuBarMode ? "Switch to window" : "Move to menu bar")
    }
}

struct Caption: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 2) {
            switch model.phase {
            case .setup(let step):
                Text("Step \((model.setupSteps.firstIndex(of: step) ?? 0) + 1) of \(model.setupSteps.count) · \(step.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(model.setupNote ?? step.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(model.setupNote == nil ? Color(white: 0.6) : Color.accentColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            case .ready:
                Text("Ready!")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text("Copy a link to begin")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.6))
            case .idle:
                if let s = model.suggestion {
                    Text(s.title ?? s.source.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("Click to download")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("Paste link  ⌘V")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(white: 0.6))
                }
            case .quality(_, .audio):
                FormatPill()
            case .done(let url):
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Drag to move")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.6))
            case .failed:
                Text("Failed · try again ⌘V")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.6))
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 38)
        .frame(height: 34, alignment: .top)
    }
}

struct FormatPill: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AudioFormat.allCases, id: \.self) { f in
                Button { model.audioFormat = f } label: {
                    Text(f.rawValue)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(model.audioFormat == f ? Color.white : Color(white: 0.55))
                        .frame(width: 46, height: 22)
                        .background(Capsule().fill(model.audioFormat == f ? Color(white: 0.38) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color(white: 0.22)))
        .animation(.snappy(duration: 0.2), value: model.audioFormat)
    }
}

struct ArrowDown: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.move(to: CGPoint(x: r.minX, y: r.maxY - r.width / 2))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.width / 2))
        return p
    }
}

/// Small circle that pops up in the middle on hover: a peek of the artwork (or the source icon
/// until it arrives), with a tiny source badge.
struct HintBubble: View {
    let hint: Suggestion

    var body: some View {
        let tint = hint.art?.colors.first ?? Color(white: 0.5)
        ZStack {
            if let art = hint.art {
                Image(nsImage: art.nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                Image(systemName: hint.source.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(tint))
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                    .offset(x: 23, y: 23)
            } else {
                Image(systemName: hint.source.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(
                        Circle().fill(tint.opacity(0.55))
                            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    )
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .animation(.easeInOut(duration: 0.35), value: hint.art != nil)
    }
}

struct Stack<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 4) { content }.transition(.opacity)
    }
}

struct Option: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.85))
                .shadow(color: .black.opacity(0.35), radius: 3)
                .frame(width: 104, height: 28)
                .background(Capsule().fill(.white.opacity(hover ? 0.18 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

