import CGTK
import PeaCore
import Foundation

struct Actions {
    var clickHero: () -> Void = {}
    var performSetup: () -> Void = {}
    var skipSetup: () -> Void = {}
    var chooseKind: (Kind) -> Void = { _ in }
    var chooseQuality: (Quality) -> Void = { _ in }
    var setFormat: (AudioFormat) -> Void = { _ in }
    var open: (URL) -> Void = { _ in }
    var warmHint: () -> Void = {}
    var toggleMode: () -> Void = {}
    var close: () -> Void = {}
}

enum Hit: Equatable { case none, hero, option(Int), pill(Int), file, skip, toggle, close }

/// Everything drawn in the window, laid out exactly like the macOS app (232x266, 172pt ring,
/// 142pt circle). Pure drawing + animation state; GTK plumbing lives in `PeaWindow`.
@MainActor
final class Scene {
    nonisolated static let W = 232.0, H = 266.0
    static let cx = 116.0, cy = 120.0                  // hero centre
    nonisolated static let ringR = 84.0, circleR = 71.0, heroR = 86.0
    static let captionTop = 214.0

    var actions = Actions()
    var requestFrame: () -> Void = {}
    var accent = Col(0.04, 0.52, 1.0)
    var trayAvailable = false
    var trayMode = false

    private(set) var state = ViewState()
    private var prevHero: ViewState?, prevCap: ViewState?
    private var heroX = Chan(1), capX = Chan(1)
    private var litC = Chan(), hoverC = Chan(), hintC = Chan(), arrowC = Chan(1), artC = Chan()
    private var progC = Chan(), setupC = Chan(), grownC = Chan(), expandA = Chan(1), badgeC = Chan()
    private var pillC = Chan(), windowC = Chan(), hintArtC = Chan()
    private var optC = [Chan](repeating: Chan(), count: 4)
    private var artShown: Artwork?, badgeShown: Source?
    private var thumb: FileThumb?
    private var readyStart = -100.0
    private var expansion: Suggestion?
    var motion = Motion.quick

    private(set) var hover = false
    private var pointer: (x: Double, y: Double)?
    private var hoverHit = Hit.none
    var currentHit: Hit { hoverHit }

    // MARK: State in

    func apply(_ new: ViewState) {
        let now = nowSec()
        let (dur, curve) = motion.params
        let old = state
        let firstTime = (prevHero == nil && prevCap == nil && state.screen == .idle && !didInit)
        didInit = true
        state = new
        if old.screen != new.screen && !firstTime {
            prevHero = old
            heroX.snap(0); heroX.go(1, now, 0.3, .easeOut)
            if case .done(let u) = new.screen { makeThumb(u) }
        } else if case .done(let u) = new.screen, thumb?.url != u { makeThumb(u) }
        if new.isReady && !old.isReady { readyStart = now }
        if old.captionKey != new.captionKey && !firstTime {
            prevCap = old
            capX.snap(0); capX.go(1, now, motion == .snappy ? 0.3 : dur, .easeInOut)
        }
        litC.go(new.lit ? 1 : 0, now, dur, curve)
        if let a = new.art {
            if artShown !== a { if artShown == nil { artC.snap(0) }; artShown = a }
            artC.go(1, now, 0.4, .easeInOut)
        } else { artC.go(0, now, 0.3, .easeOut) }
        if let p = new.progress { progC.go(p, now, 0.6, .easeOut) } else { progC.snap(0) }
        setupC.go(Double(new.setupDone), now, 0.6, .easeOut)
        if let b = new.badge { badgeShown = b; badgeC.go(1, now, 0.4, .spring) } else { badgeC.go(0, now, 0.2, .easeOut) }
        let fi = AudioFormat.allCases.firstIndex(of: new.audioFormat) ?? 0
        pillC.go(Double(fi), now, 0.2, .easeOut)
        if firstTime { litC.snap(new.lit ? 1 : 0); artC.snap(new.art != nil ? 1 : 0); badgeC.snap(new.badge != nil ? 1 : 0); pillC.snap(Double(fi)); setupC.snap(Double(new.setupDone)); if let p = new.progress { progC.snap(p) } }
        derived(now)
        requestFrame()
    }
    private var didInit = false

    private func makeThumb(_ u: URL) {
        let t = FileThumb(url: u)
        t.onReady = { [weak self] in self?.requestFrame() }
        thumb = t
    }

    private var showHint: Bool { state.isIdle && !state.armed && state.hint != nil && hover && expansion == nil }

    private func derived(_ now: Double) {
        hoverC.go(hover ? 1 : 0, now, 0.3, .easeOut)
        hintC.go(showHint ? 1 : 0, now, showHint ? 0.5 : 0.25, showHint ? .spring : .easeOut)
        arrowC.go(showHint || expansion != nil ? 0 : 1, now, 0.15, .easeOut)
        hintArtC.go(state.hint?.art != nil ? 1 : 0, now, 0.35, .easeInOut)
        for i in 0..<optC.count { optC[i].go(hoverHit == .option(i) ? 1 : 0, now, 0.12, .easeOut) }
    }

    func setWindowHover(_ inside: Bool) { windowC.go(inside ? 1 : 0, nowSec(), 0.2, .easeOut); requestFrame() }

    // MARK: Pointer

    func pointerMoved(_ x: Double, _ y: Double) {
        pointer = (x, y)
        hoverHit = hit(x, y)
        let inside = hypot(x - Self.cx, y - Self.cy) <= Self.heroR
        if inside != hover {
            hover = inside
            if inside { actions.warmHint() }
        }
        derived(nowSec())
        requestFrame()
    }

    func pointerLeft() {
        pointer = nil; hoverHit = .none
        if hover { hover = false }
        derived(nowSec()); requestFrame()
    }

    func interactive(_ h: Hit) -> Bool {
        switch h {
        case .none: return false
        case .hero: return state.armed || state.isSetup || showHint
        default: return true
        }
    }

    func click(_ h: Hit) {
        switch h {
        case .hero:
            if state.armed { actions.clickHero() }
            else if state.isSetup { actions.performSetup() }
            else if showHint { expandHint() }
        case .option(let i):
            switch state.screen {
            case .kind: actions.chooseKind(i == 0 ? .video : .audio)
            case .quality: if i < Quality.allCases.count { actions.chooseQuality(Quality.allCases[i]) }
            default: break
            }
        case .pill(let i): actions.setFormat(AudioFormat.allCases[i])
        case .skip: actions.skipSetup()
        case .toggle: actions.toggleMode()
        case .close: actions.close()
        default: break
        }
    }

    /// Click on the hover hint: its circle grows to fill ours, then the next screen takes over.
    private func expandHint() {
        guard let h = state.hint else { return }
        let now = nowSec()
        expansion = h
        grownC.snap(0.42); grownC.go(1, now, 0.38, .easeInOut)
        expandA.snap(1)
        derived(now); requestFrame()
        after(ms: 400) { [self] in
            actions.open(h.url)
            after(ms: 350) { [self] in
                expandA.go(0, nowSec(), 0.3, .easeOut)
                requestFrame()
                after(ms: 320) { [self] in expansion = nil; derived(nowSec()); requestFrame() }
            }
        }
    }

    // MARK: Layout / hit testing

    private func optionRows() -> [String] {
        switch state.screen {
        case .kind: return ["Video", "Audio"]
        case .quality: return Quality.allCases.map(\.rawValue)
        default: return []
        }
    }
    private func optionRect(_ i: Int, of n: Int) -> (x: Double, y: Double, w: Double, h: Double) {
        let total = Double(n) * 28 + Double(n - 1) * 4
        return (Self.cx - 52, Self.cy - total / 2 + Double(i) * 32, 104, 28)
    }
    private func pillRect(_ i: Int) -> (x: Double, y: Double, w: Double, h: Double) {
        let total = 46.0 * 3 + 2 * 2 + 4
        let x0 = Self.cx - total / 2 + 2
        return (x0 + Double(i) * 48, Self.captionTop + 2, 46, 22)
    }
    static let toggleRect = (x: 10.0, y: H - 36, w: 26.0, h: 26.0)
    static let skipRect = (x: W - 14 - 46, y: H - 14 - 22, w: 54.0, h: 30.0)
    static let closeRect = (x: W - 26, y: 6.0, w: 20.0, h: 20.0)
    var fileRect: (x: Double, y: Double, w: Double, h: Double) { (Self.cx - 46, Self.cy - 46, 92, 92) }

    private func inside(_ r: (x: Double, y: Double, w: Double, h: Double), _ x: Double, _ y: Double) -> Bool {
        x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h
    }

    func hit(_ x: Double, _ y: Double) -> Hit {
        if inside(Self.closeRect, x, y) { return .close }
        if trayAvailable && inside(Self.toggleRect, x, y) { return .toggle }
        if state.isSetup && inside(Self.skipRect, x, y) { return .skip }
        if case .quality(.audio) = state.screen {
            for i in 0..<3 where inside(pillRect(i), x, y) { return .pill(i) }
        }
        let rows = optionRows()
        for i in 0..<rows.count where inside(optionRect(i, of: rows.count), x, y) { return .option(i) }
        if case .done = state.screen, inside(fileRect, x, y) { return .file }
        if hypot(x - Self.cx, y - Self.cy) <= Self.heroR { return .hero }
        return .none
    }

    func dragFile(_ x: Double, _ y: Double) -> (url: URL, thumb: FileThumb?)? {
        if case .done(let u) = state.screen, hit(x, y) == .file { return (u, thumb) }
        return nil
    }

    func tooltip(_ x: Double, _ y: Double) -> String? {
        switch hit(x, y) {
        case .file: return "Drag to move"
        case .toggle: return trayMode ? "Switch to window" : "Move to tray"
        case .hero:
            if case .failed(let m) = state.screen { return m }
            if hypot(x - (Self.cx + 50), y - (Self.cy + 50)) < 15 {
                return state.badge?.name
            }
            return nil
        default: return nil
        }
    }

    // MARK: Frame

    func animating(_ now: Double) -> Bool {
        if heroX.active(now) || capX.active(now) || litC.active(now) || hoverC.active(now) || hintC.active(now)
            || arrowC.active(now) || artC.active(now) || progC.active(now) || setupC.active(now) || grownC.active(now)
            || expandA.active(now) || badgeC.active(now) || pillC.active(now) || windowC.active(now) || hintArtC.active(now)
            || optC.contains(where: { $0.active(now) }) { return true }
        if state.waving || (state.isWorking && state.progress == nil) { return true }
        if hintC.value(now) > 0.001 || hintC.to > 0 { return true }
        if state.isReady && now - readyStart < 1.7 { return true }
        return expansion != nil
    }

    func settle(_ now: Double) {
        if prevHero != nil && !heroX.active(now) { prevHero = nil }
        if prevCap != nil && !capX.active(now) { prevCap = nil }
        if artC.to == 0 && !artC.active(now) { artShown = nil }
        if badgeC.to == 0 && !badgeC.active(now) { badgeShown = nil }
    }

    // MARK: Drawing

    func draw(_ cr: Cr, _ now: Double) {
        settle(now)
        cr.color(Col(0.155, 0.16, 0.158)); cairo_paint(cr)
        drawHero(cr, now)
        let capA = capX.value(now)
        if let p = prevCap { grouped(cr, alpha: 1 - capA) { drawCaption(cr, p, now) } }
        grouped(cr, alpha: prevCap == nil ? 1 : capA) { drawCaption(cr, state, now) }
        drawChrome(cr, now)
    }

    private func palette() -> [Col] {
        let cols = (artShown?.palette ?? []).map { Col($0.r, $0.g, $0.b) }
        return cols.isEmpty ? [accent, accent.alpha(0.6)] : cols
    }

    private func drawHero(_ cr: Cr, _ now: Double) {
        let cx = Self.cx, cy = Self.cy
        drawRing(cr, now)

        let lit = litC.value(now), hov = hoverC.value(now)
        let circleScale = 1 + 0.04 * hov * lit
        fillCircle(cr, cx, cy, Self.circleR * circleScale, Col.mix(Col(white: 0.27), accent, lit))

        if let art = artShown {
            let a = artC.value(now)
            let s = 1 + (state.armed ? 0.04 * hov : 0)
            grouped(cr, alpha: a) { drawGlass(cr, art, cx: cx, cy: cy, r: Self.circleR * s) }
        }

        if let h = expansion {
            let g = grownC.value(now)
            grouped(cr, alpha: expandA.value(now)) {
                if let art = h.art { drawGlass(cr, art, cx: cx, cy: cy, r: Self.circleR * g) }
                else { fillCircle(cr, cx, cy, Self.circleR * g, accent) }
            }
        }

        let x = heroX.value(now)
        if let p = prevHero { drawContent(cr, p, alpha: 1 - x, now: now) }
        drawContent(cr, state, alpha: prevHero == nil ? 1 : x, now: now)

        let hp = hintC.value(now)
        if hp > 0.002, let h = state.hint ?? lastHint {
            lastHint = h
            if let t = h.title { drawCircularText(cr, t, now: now, alpha: min(1, hp)) }
            drawHintBubble(cr, h, pop: hp, now: now)
        }

        let b = badgeC.value(now)
        if b > 0.002, let src = badgeShown {
            let armed = state.armed
            let bx = cx + 50, by = cy + 50
            grouped(cr, alpha: min(1, b)) {
                cairo_save(cr)
                cairo_translate(cr, bx, by); cairo_scale(cr, 0.5 + 0.5 * b, 0.5 + 0.5 * b); cairo_translate(cr, -bx, -by)
                fillCircle(cr, bx, by, 15, armed ? .white : Col(white: 0.2))
                Icons.source(cr, key: src.icon, cx: bx, cy: by, size: 14, color: armed ? accent : Col(white: 0.8))
                cairo_restore(cr)
            }
        }
    }
    private var lastHint: Suggestion?

    // Ring ------------------------------------------------------------------

    private static let grey = Col(white: 0.36)

    private func dotPos(_ i: Int, _ r: Double = Scene.ringR) -> (Double, Double, Double) {
        let a = Double(i) / 72 * 2 * .pi
        return (Self.cx + r * cos(a), Self.cy + r * sin(a), a)
    }

    private func greyDots(_ cr: Cr) {
        for i in 0..<72 { let p = dotPos(i); fillCircle(cr, p.0, p.1, 1.3, Self.grey) }
    }

    /// Dots counted from 12 o'clock (the macOS ring is rotated -90°).
    private func topDot(_ i: Int) -> (Double, Double) {
        let a = Double(i) / 72 * 2 * .pi - .pi / 2
        return (Self.cx + Self.ringR * cos(a), Self.cy + Self.ringR * sin(a))
    }

    private func drawRing(_ cr: Cr, _ now: Double) {
        let s = state
        if let st = s.setupRing {
            greyDots(cr)
            let total = Double(st.total)
            let done = setupC.value(now) / total
            let next = min(1, (setupC.value(now) + 1) / total)
            let doneTarget = Double(st.done)
            _ = doneTarget
            for i in 0..<72 {
                let t = Double(i) / 72
                let p = topDot(i)
                if t <= next + 1e-9 && (t > done || done == 0) && !s.isReady { fillCircle(cr, p.0, p.1, 1.5, accent.alpha(0.35)) }
                if done > 0 && t <= done + 1e-9 { fillCircle(cr, p.0, p.1, 1.7, accent) }
            }
            if s.isReady { for i in 0..<72 { let p = topDot(i); fillCircle(cr, p.0, p.1, 1.7, accent) } }
        } else if s.isWorking {
            greyDots(cr)
            if s.progress != nil {
                let p = progC.value(now)
                if p > 0 { for i in 0..<72 where Double(i) / 72 <= p + 1e-9 { let d = topDot(i); fillCircle(cr, d.0, d.1, 1.7, accent) } }
            } else {
                // Comet: a bright head with a fading tail of accent dots chasing round.
                let head = (now / 2.2).truncatingRemainder(dividingBy: 1) * 72
                for i in 0..<72 {
                    var d = head - Double(i); if d < 0 { d += 72 }
                    if d < 16 { let k = 1 - d / 16; let p = topDot(i); fillCircle(cr, p.0, p.1, 1.3 + 0.5 * k, accent.alpha(0.15 + 0.85 * k)) }
                }
            }
        } else if s.waving {
            let cs = palette()
            let colors = cs.count > 1 ? cs : [cs[0], cs[0].alpha(0.4)]
            let ring = colors + [colors[0]]
            let rot = (now / 30).truncatingRemainder(dividingBy: 1)         // one lap ≈ 30 s
            for i in 0..<72 {
                var pos = Double(i) / 72 - rot
                pos -= floor(pos)
                let seg = pos * Double(ring.count - 1)
                let k = min(ring.count - 2, Int(seg)), t = seg - Double(k)
                let c = Col.mix(ring[k], ring[k + 1], t)
                let p = dotPos(i); fillCircle(cr, p.0, p.1, 1.6, c)
            }
        } else {
            greyDots(cr)
        }
    }

    // Glass -----------------------------------------------------------------

    private func drawGlass(_ cr: Cr, _ art: Artwork, cx: Double, cy: Double, r: Double) {
        circleShadow(cr, cx, cy, r, blur: 8, dy: 3, alpha: 0.25)
        cairo_save(cr)
        circlePath(cr, cx, cy, r); cairo_clip(cr)
        if let img = art.image {
            let size = r * 2 * 1.5
            paintSurface(cr, img.glass, x: cx - size / 2, y: cy - size / 2, w: size, h: size)
        } else {
            fillCircle(cr, cx, cy, r, Col(white: 0.4))
        }
        cr.color(Col.black.alpha(0.18)); cairo_paint(cr)
        setGradient(cr, cx - r, cy - r, cx + r, cy + r, [(0, Col.white.alpha(0.28)), (0.5, Col.white.alpha(0)), (1, Col.white.alpha(0.06))])
        cairo_paint(cr)
        cairo_restore(cr)
        // 1px rim, light at the top-left
        circlePath(cr, cx, cy, r - 0.5)
        setGradient(cr, cx - r, cy - r, cx + r, cy + r, [(0, Col.white.alpha(0.55)), (0.5, Col.white.alpha(0.05)), (1, Col.white.alpha(0.25))])
        cairo_set_line_width(cr, 1); cairo_stroke(cr)
    }

    // Content ---------------------------------------------------------------

    private func drawContent(_ cr: Cr, _ st: ViewState, alpha: Double, now: Double) {
        let cx = Self.cx, cy = Self.cy
        grouped(cr, alpha: alpha) {
            switch st.screen {
            case .working:
                if let p = st.progress {
                    drawTextMid(cr, "\(Int(p * 100))", cx: cx, cy: cy, size: 30, weight: .light, color: Col.white.alpha(0.7))
                }
            case .done:
                cairo_save(cr)
                let k = 0.6 + 0.4 * alpha
                cairo_translate(cr, cx, cy); cairo_scale(cr, k, k); cairo_translate(cr, -cx, -cy)
                thumb?.draw(cr, cx: cx, cy: cy, box: 92)
                cairo_restore(cr)
            case .failed:
                strokeStyle(cr, 4.2)
                cr.color(Col.white.alpha(0.55))
                cairo_move_to(cr, cx, cy - 18); cairo_line_to(cr, cx, cy + 3); cairo_stroke(cr)
                fillCircle(cr, cx, cy + 14, 2.5, Col.white.alpha(0.55))
            case .kind:
                drawOptions(cr, ["Video", "Audio"], now: now, live: st.screen == state.screen)
            case .quality:
                drawOptions(cr, Quality.allCases.map(\.rawValue), now: now, live: st.screen == state.screen)
            case .ready:
                drawReady(cr, now)
            case .setup:
                if let step = st.setupStep {
                    Icons.setup(cr, key: step.icon, cx: cx, cy: cy - 9.5, size: 36, color: .white)
                    drawTextMid(cr, st.setupBusy ? "Working…" : "Click to \(step.action.lowercased())", cx: cx, cy: cy + 20,
                                size: 12, weight: .medium, color: Col.white.alpha(0.85))
                }
            case .idle:
                let a = arrowC.value(now)
                let c = Col.mix(Col(white: 0.58), .white, litC.value(now))
                let x = cx - 17, y = cy - 22, w = 34.0, h = 44.0
                cr.color(c.alpha(c.a * a))
                strokeStyle(cr, 3)
                cairo_move_to(cr, x + w / 2, y); cairo_line_to(cr, x + w / 2, y + h)
                cairo_move_to(cr, x, y + h - w / 2); cairo_line_to(cr, x + w / 2, y + h); cairo_line_to(cr, x + w, y + h - w / 2)
                cairo_stroke(cr)
            }
        }
    }

    private func drawOptions(_ cr: Cr, _ rows: [String], now: Double, live: Bool) {
        for (i, t) in rows.enumerated() {
            let r = optionRect(i, of: rows.count)
            let h = live && i < optC.count ? optC[i].value(now) : 0
            if h > 0.001 { fillCapsule(cr, r.x, r.y, r.w, r.h, Col.white.alpha(0.18 * h)) }
            drawTextMid(cr, t, cx: r.x + r.w / 2, cy: r.y + r.h / 2 + 1, size: 14, weight: .medium, color: Col.black.alpha(0.18))
            drawTextMid(cr, t, cx: r.x + r.w / 2, cy: r.y + r.h / 2, size: 14, weight: .medium, color: Col.white.alpha(0.85 + 0.15 * h))
        }
    }

    private func drawReady(_ cr: Cr, _ now: Double) {
        let t = now - readyStart
        let drawn = ease(.easeOut, (t - 0.15) / 0.55)
        let bloom = ease(.easeOut, (t - 0.45) / 1.0)
        let cx = Self.cx, cy = Self.cy
        if bloom < 1 {
            circlePath(cr, cx, cy, Self.circleR * (1 + 0.35 * bloom))
            cr.color(Col.white.alpha(0.5 * 0.8 * (1 - bloom)))
            cairo_set_line_width(cr, 2); cairo_stroke(cr)
        }
        let ox = cx - 27, oy = cy - 20
        let pts = trimmedPolyline([(ox, oy + 24), (ox + 19.44, oy + 40), (ox + 54, oy)], drawn)
        if pts.count > 1 {
            strokeStyle(cr, 6)
            cr.color(.white)
            cairo_move_to(cr, pts[0].0, pts[0].1)
            for p in pts.dropFirst() { cairo_line_to(cr, p.0, p.1) }
            cairo_stroke(cr)
        }
    }

    // Hover hint ------------------------------------------------------------

    private func drawHintBubble(_ cr: Cr, _ h: Suggestion, pop: Double, now: Double) {
        let cx = Self.cx, cy = Self.cy
        let tint = h.art?.palette.first.map { Col($0.r, $0.g, $0.b) } ?? Col(white: 0.5)
        let s = 0.2 + 0.8 * pop
        grouped(cr, alpha: min(1, pop * 1.5)) {
            cairo_save(cr)
            cairo_translate(cr, cx, cy); cairo_scale(cr, s, s); cairo_translate(cr, -cx, -cy)
            circleShadow(cr, cx, cy, 32, blur: 8, dy: 3, alpha: 0.35)
            if let img = h.art?.image {
                cairo_save(cr); circlePath(cr, cx, cy, 32); cairo_clip(cr)
                paintSurface(cr, img.sharp, x: cx - 32, y: cy - 32, w: 64, h: 64)
                cairo_restore(cr)
                circlePath(cr, cx, cy, 31.5); cr.color(Col.white.alpha(0.4)); cairo_set_line_width(cr, 1); cairo_stroke(cr)
                fillCircle(cr, cx + 23, cy + 23, 10, tint)
                circlePath(cr, cx + 23, cy + 23, 9.5); cr.color(Col.white.alpha(0.6)); cairo_stroke(cr)
                Icons.source(cr, key: h.source.icon, cx: cx + 23, cy: cy + 23, size: 11, color: .white)
            } else {
                fillCircle(cr, cx, cy, 32, tint.alpha(0.55))
                circlePath(cr, cx, cy, 31.5); cr.color(Col.white.alpha(0.35)); cairo_set_line_width(cr, 1); cairo_stroke(cr)
                Icons.source(cr, key: h.source.icon, cx: cx, cy: cy, size: 24, color: .white)
            }
            cairo_restore(cr)
        }
    }

    private func drawCircularText(_ cr: Cr, _ text: String, now: Double, alpha: Double) {
        let base = Array(String(text.prefix(40)) + "  •  ")
        let reps = max(1, Int((84.0 / Double(base.count)).rounded()))
        let chars = Array((0..<reps).flatMap { _ in base })
        let spin = (now / 26).truncatingRemainder(dividingBy: 1) * 2 * .pi
        grouped(cr, alpha: alpha) {
            for (i, ch) in chars.enumerated() {
                if ch == " " { continue }
                cairo_save(cr)
                cairo_translate(cr, Self.cx, Self.cy)
                cairo_rotate(cr, Double(i) / Double(chars.count) * 2 * .pi + spin)
                drawTextMid(cr, String(ch), cx: 0, cy: -77.5, size: 8.5, weight: .semibold, color: Col.white.alpha(0.7), mono: true)
                cairo_restore(cr)
            }
        }
    }

    // Caption ---------------------------------------------------------------

    private func drawCaption(_ cr: Cr, _ st: ViewState, _ now: Double) {
        let x = Self.W / 2, y0 = Self.captionTop, mw = Self.W - 76
        let white = Col.white, dim = Col(white: 0.6)
        switch st.screen {
        case .setup:
            guard let step = st.setupStep else { return }
            let b = drawText(cr, "Step \(st.setupDone + 1) of \(st.setupTotal) · \(step.title)", x: x, top: y0, size: 13,
                             weight: .semibold, color: white, maxWidth: mw)
            drawText(cr, st.setupNote ?? step.reason, x: x, top: y0 + b.h + 2, size: 12,
                     color: st.setupNote == nil ? dim : accent, maxWidth: mw, lines: 2)
        case .ready:
            let b = drawText(cr, "Ready!", x: x, top: y0, size: 17, weight: .bold, color: white)
            drawText(cr, "Copy a link to begin", x: x, top: y0 + b.h + 2, size: 12, color: dim)
        case .idle:
            if let s = st.suggestion {
                let b = drawText(cr, s.title ?? s.source.name, x: x, top: y0, size: 13, weight: .semibold, color: white, maxWidth: mw)
                drawText(cr, "Click to download", x: x, top: y0 + b.h + 2, size: 12, color: accent)
            } else {
                drawText(cr, "Paste link  Ctrl+V", x: x, top: y0, size: 13, weight: .medium, color: dim)
            }
        case .quality(.audio): drawPill(cr, st, now)
        case .done(let url):
            let b = drawText(cr, url.lastPathComponent, x: x, top: y0, size: 13, weight: .semibold, color: white, maxWidth: mw, middle: true)
            drawText(cr, "Drag to move", x: x, top: y0 + b.h + 2, size: 12, color: dim)
        case .failed:
            drawText(cr, "Failed · try again Ctrl+V", x: x, top: y0, size: 13, weight: .medium, color: dim)
        default: break
        }
    }

    private func drawPill(_ cr: Cr, _ st: ViewState, _ now: Double) {
        let r0 = pillRect(0)
        fillCapsule(cr, r0.x - 2, r0.y - 2, 46 * 3 + 2 * 2 + 4, 26, Col(white: 0.22))
        let sel = pillC.value(now)
        fillCapsule(cr, r0.x + sel * 48, r0.y, 46, 22, Col(white: 0.38))
        for (i, f) in AudioFormat.allCases.enumerated() {
            let r = pillRect(i)
            let on = max(0, 1 - abs(sel - Double(i)))
            drawTextMid(cr, f.rawValue, cx: r.x + 23, cy: r.y + 11, size: 11.5, weight: .semibold,
                        color: Col.mix(Col(white: 0.55), .white, on))
        }
    }

    // Chrome ------------------------------------------------------------------

    private func drawChrome(_ cr: Cr, _ now: Double) {
        if trayAvailable {
            let r = Self.toggleRect
            let c = hoverHit == .toggle ? Col.white : Col(white: 0.5)
            let cx = r.x + r.w / 2, cy = r.y + r.h / 2
            strokeStyle(cr, 1.5)
            roundRectPath(cr, cx - 7.5, cy - 5.5, 15, 11, 2.2); cr.color(c); cairo_stroke(cr)
            if trayMode {   // window glyph: title bar rule
                cairo_move_to(cr, cx - 7.5, cy - 2); cairo_line_to(cr, cx + 7.5, cy - 2); cairo_stroke(cr)
            } else {        // tray glyph: filled bar on top
                roundRectPath(cr, cx - 7.5, cy - 5.5, 15, 3.6, 1.2); cairo_fill(cr)
            }
        }
        if state.isSetup {
            let hv = hoverHit == .skip
            drawText(cr, "Skip", x: Self.W - 14, top: Self.H - 14 - 15, size: 12, color: hv ? Col(white: 0.8) : Col(white: 0.5), h: .right)
        }
        let w = windowC.value(now)
        if w > 0.01 {
            let r = Self.closeRect, c = Col(white: hoverHit == .close ? 0.95 : 0.5, w * 0.9)
            strokeStyle(cr, 1.6); cr.color(c)
            let cx = r.x + r.w / 2, cy = r.y + r.h / 2
            cairo_move_to(cr, cx - 4, cy - 4); cairo_line_to(cr, cx + 4, cy + 4)
            cairo_move_to(cr, cx + 4, cy - 4); cairo_line_to(cr, cx - 4, cy + 4); cairo_stroke(cr)
        }
    }
}
