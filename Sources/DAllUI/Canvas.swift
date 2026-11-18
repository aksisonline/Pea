import CGTK
import Foundation

typealias Cr = OpaquePointer

struct Col {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(white: Double, _ a: Double = 1) { self.init(white, white, white, a) }
    func alpha(_ k: Double) -> Col { Col(r, g, b, a * k) }
    static let white = Col(white: 1)
    static let black = Col(white: 0)
    static func mix(_ x: Col, _ y: Col, _ t: Double) -> Col {
        Col(x.r + (y.r - x.r) * t, x.g + (y.g - x.g) * t, x.b + (y.b - x.b) * t, x.a + (y.a - x.a) * t)
    }
}

extension Cr {
    func color(_ c: Col) { cairo_set_source_rgba(self, c.r, c.g, c.b, c.a) }
}

// MARK: Shapes

func circlePath(_ cr: Cr, _ cx: Double, _ cy: Double, _ r: Double) {
    cairo_new_sub_path(cr)
    cairo_arc(cr, cx, cy, r, 0, 2 * .pi)
}

func fillCircle(_ cr: Cr, _ cx: Double, _ cy: Double, _ r: Double, _ c: Col) {
    circlePath(cr, cx, cy, r); cr.color(c); cairo_fill(cr)
}

func capsulePath(_ cr: Cr, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
    roundRectPath(cr, x, y, w, h, min(w, h) / 2)
}

func roundRectPath(_ cr: Cr, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) {
    let r = min(r, w / 2, h / 2)
    cairo_new_sub_path(cr)
    cairo_arc(cr, x + w - r, y + r, r, -.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, .pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, .pi / 2, .pi)
    cairo_arc(cr, x + r, y + r, r, .pi, 3 * .pi / 2)
    cairo_close_path(cr)
}

func fillCapsule(_ cr: Cr, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Col) {
    capsulePath(cr, x, y, w, h); cr.color(c); cairo_fill(cr)
}

func strokeStyle(_ cr: Cr, _ width: Double, round: Bool = true) {
    cairo_set_line_width(cr, width)
    cairo_set_line_cap(cr, round ? CAIRO_LINE_CAP_ROUND : CAIRO_LINE_CAP_BUTT)
    cairo_set_line_join(cr, round ? CAIRO_LINE_JOIN_ROUND : CAIRO_LINE_JOIN_MITER)
}

/// Soft drop shadow for a circle, approximated with stacked translucent discs (Cairo has no blur).
func circleShadow(_ cr: Cr, _ cx: Double, _ cy: Double, _ r: Double, blur: Double, dy: Double, alpha: Double) {
    let steps = 8
    for i in 0..<steps {
        let t = Double(i) / Double(steps - 1)            // 0 = outermost
        let rr = r + blur * (1 - t) * 0.9 - blur * 0.15
        fillCircle(cr, cx, cy + dy, rr, Col.black.alpha(alpha / Double(steps) * 1.4))
    }
}

// MARK: Text (Pango)

enum Weight: UInt32 { case light = 300, regular = 400, medium = 500, semibold = 600, bold = 700 }

private let sansFamilies = "Inter, Cantarell, Noto Sans, DejaVu Sans, Sans"
private let monoFamilies = "JetBrains Mono, DejaVu Sans Mono, Noto Sans Mono, Monospace"

struct TextBox { var w: Double; var h: Double }

/// Builds a layout for `s`. Sizes are CSS pixels, like the macOS point sizes in the spec.
func makeLayout(_ cr: Cr, _ s: String, size: Double, weight: Weight = .regular, mono: Bool = false,
                maxWidth: Double? = nil, lines: Int = 1, center: Bool = false,
                middle: Bool = false) -> OpaquePointer {
    let layout = pango_cairo_create_layout(cr)!
    let fd = pango_font_description_new()!
    pango_font_description_set_family(fd, mono ? monoFamilies : sansFamilies)
    pango_font_description_set_weight(fd, PangoWeight(rawValue: weight.rawValue))
    pango_font_description_set_absolute_size(fd, size * 1024)
    pango_layout_set_font_description(layout, fd)
    pango_font_description_free(fd)
    pango_layout_set_text(layout, s, -1)
    if let maxWidth {
        pango_layout_set_width(layout, Int32(maxWidth * 1024))
        pango_layout_set_ellipsize(layout, middle ? PANGO_ELLIPSIZE_MIDDLE : PANGO_ELLIPSIZE_END)
        pango_layout_set_height(layout, Int32(-lines))
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
    }
    if center { pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER) }
    return layout
}

func layoutSize(_ l: OpaquePointer) -> TextBox {
    var w: Int32 = 0, h: Int32 = 0
    pango_layout_get_pixel_size(l, &w, &h)
    return TextBox(w: Double(w), h: Double(h))
}

enum HAnchor { case left, center, right }

/// Draws text with its anchor point at x (horizontal) and `top`; returns the box.
@discardableResult
func drawText(_ cr: Cr, _ s: String, x: Double, top: Double, size: Double, weight: Weight = .regular,
              color: Col, h: HAnchor = .center, mono: Bool = false, maxWidth: Double? = nil, lines: Int = 1,
              middle: Bool = false) -> TextBox {
    let l = makeLayout(cr, s, size: size, weight: weight, mono: mono, maxWidth: maxWidth, lines: lines, center: h == .center, middle: middle)
    defer { g_object_unref(Ptr(l)) }
    let box = layoutSize(l)
    let left: Double
    switch h {
    case .left: left = x
    case .center: left = maxWidth != nil ? x - maxWidth! / 2 : x - box.w / 2
    case .right: left = x - box.w
    }
    cairo_save(cr)
    cairo_move_to(cr, left, top)
    cr.color(color)
    pango_cairo_update_layout(cr, l)
    pango_cairo_show_layout(cr, l)
    cairo_restore(cr)
    return box
}

/// Text centred on (cx, cy).
@discardableResult
func drawTextMid(_ cr: Cr, _ s: String, cx: Double, cy: Double, size: Double, weight: Weight = .regular,
                 color: Col, mono: Bool = false) -> TextBox {
    let l = makeLayout(cr, s, size: size, weight: weight, mono: mono)
    defer { g_object_unref(Ptr(l)) }
    let box = layoutSize(l)
    cairo_save(cr)
    cairo_move_to(cr, cx - box.w / 2, cy - box.h / 2)
    cr.color(color)
    pango_cairo_update_layout(cr, l)
    pango_cairo_show_layout(cr, l)
    cairo_restore(cr)
    return box
}

func measure(_ cr: Cr, _ s: String, size: Double, weight: Weight = .regular, maxWidth: Double? = nil, lines: Int = 1) -> TextBox {
    let l = makeLayout(cr, s, size: size, weight: weight, maxWidth: maxWidth, lines: lines)
    defer { g_object_unref(Ptr(l)) }
    return layoutSize(l)
}

// MARK: Icons (vector, drawn in a unit box centred on the origin, `s` = box size)

enum Icons {
    static func source(_ cr: Cr, key: String, cx: Double, cy: Double, size s: Double, color: Col) {
        cairo_save(cr)
        cairo_translate(cr, cx, cy)
        cairo_scale(cr, s / 20, s / 20)          // design grid is 20x20
        cr.color(color)
        switch key {
        case "music": music(cr)
        case "waveform": waveform(cr)
        case "video": playRect(cr)
        case "camera": camera(cr)
        case "chat": chat(cr)
        case "pin": pin(cr)
        default: globe(cr)
        }
        cairo_restore(cr)
    }

    static func setup(_ cr: Cr, key: String, cx: Double, cy: Double, size s: Double, color: Col) {
        cairo_save(cr)
        cairo_translate(cr, cx, cy)
        cairo_scale(cr, s / 20, s / 20)
        cr.color(color)
        switch key {
        case "clipboard": clipboard(cr)
        case "download": download(cr)
        case "tools": wrench(cr, color)
        default: gear(cr)
        }
        cairo_restore(cr)
    }

    private static func music(_ cr: Cr) {
        cairo_save(cr); cairo_translate(cr, -4.2, 5.5); cairo_scale(cr, 1.35, 1); circlePath(cr, 0, 0, 3.2); cairo_fill(cr); cairo_restore(cr)
        cairo_rectangle(cr, 0.1, -9, 2, 14.2); cairo_fill(cr)
        cairo_move_to(cr, 2, -9); cairo_curve_to(cr, 5, -7.5, 8, -6.5, 7.6, -2.5); cairo_curve_to(cr, 6.8, -5, 5, -5.4, 2, -5); cairo_close_path(cr); cairo_fill(cr)
    }
    private static func waveform(_ cr: Cr) {
        let hs: [Double] = [5, 11, 17, 9, 14, 6]
        for (i, h) in hs.enumerated() {
            let x = -8.5 + Double(i) * 3.4
            roundRectPath(cr, x - 0.9, -h / 2, 1.8, h, 0.9); cairo_fill(cr)
        }
    }
    private static func playRect(_ cr: Cr) {
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD)
        roundRectPath(cr, -9.5, -7, 19, 14, 3)
        cairo_move_to(cr, -2.2, -3.6); cairo_line_to(cr, 3.8, 0); cairo_line_to(cr, -2.2, 3.6); cairo_close_path(cr)
        cairo_fill(cr)
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING)
    }
    private static func camera(_ cr: Cr) {
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD)
        roundRectPath(cr, -9, -5, 18, 13, 3)
        circlePath(cr, 0, 1.5, 3.6)
        cairo_fill(cr)
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING)
        roundRectPath(cr, -3.5, -8, 7, 4, 1.4); cairo_fill(cr)
    }
    private static func chat(_ cr: Cr) {
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD)
        roundRectPath(cr, -9, -8, 18, 13.5, 4)
        roundRectPath(cr, -5, -4.2, 10, 1.6, 0.8)
        roundRectPath(cr, -5, -0.6, 6.5, 1.6, 0.8)
        cairo_fill(cr)
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING)
        cairo_move_to(cr, -4, 4); cairo_line_to(cr, -5.5, 9); cairo_line_to(cr, 1, 4.5); cairo_close_path(cr); cairo_fill(cr)
    }
    private static func pin(_ cr: Cr) {
        cairo_save(cr); cairo_rotate(cr, .pi / 4)
        roundRectPath(cr, -3.2, -9, 6.4, 9.5, 2); cairo_fill(cr)
        roundRectPath(cr, -5.2, 0, 10.4, 2.4, 1.2); cairo_fill(cr)
        cairo_rectangle(cr, -0.7, 2, 1.4, 8); cairo_fill(cr)
        cairo_restore(cr)
    }
    private static func globe(_ cr: Cr) {
        strokeStyle(cr, 1.6)
        circlePath(cr, 0, 0, 8.4); cairo_stroke(cr)
        cairo_save(cr); cairo_scale(cr, 0.42, 1); circlePath(cr, 0, 0, 8.4); cairo_restore(cr); cairo_stroke(cr)
        cairo_move_to(cr, -8.4, 0); cairo_line_to(cr, 8.4, 0); cairo_stroke(cr)
    }
    private static func clipboard(_ cr: Cr) {
        strokeStyle(cr, 1.7)
        roundRectPath(cr, -6.5, -7.5, 13, 16.5, 2.4); cairo_stroke(cr)
        roundRectPath(cr, -3.6, -9.8, 7.2, 4, 1.6); cairo_fill(cr)
        cairo_move_to(cr, -3.4, -0.5); cairo_line_to(cr, 3.4, -0.5); cairo_stroke(cr)
        cairo_move_to(cr, -3.4, 3.4); cairo_line_to(cr, 2, 3.4); cairo_stroke(cr)
    }
    private static func download(_ cr: Cr) {
        strokeStyle(cr, 1.8)
        cairo_move_to(cr, 0, -8.5); cairo_line_to(cr, 0, 4); cairo_stroke(cr)
        cairo_move_to(cr, -5, -1); cairo_line_to(cr, 0, 4.4); cairo_line_to(cr, 5, -1); cairo_stroke(cr)
        cairo_move_to(cr, -7, 8.4); cairo_line_to(cr, 7, 8.4); cairo_stroke(cr)
    }
    private static func wrench(_ cr: Cr, _ color: Col) {
        cairo_push_group(cr)
        cairo_save(cr); cairo_rotate(cr, .pi / 4)
        cairo_set_source_rgba(cr, 1, 1, 1, 1)
        roundRectPath(cr, -2, -2, 4, 14.5, 2); cairo_fill(cr)
        circlePath(cr, 0, -5.2, 5.4); cairo_fill(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
        cairo_rectangle(cr, -2.1, -12, 4.2, 7.6); cairo_fill(cr)
        cairo_restore(cr)
        let pat = cairo_pop_group(cr)
        cr.color(color)
        cairo_mask(cr, pat)
        cairo_pattern_destroy(pat)
    }
    private static func gear(_ cr: Cr) {
        strokeStyle(cr, 1.8)
        circlePath(cr, 0, 0, 4); cairo_stroke(cr)
        for i in 0..<8 {
            let a = Double(i) / 8 * 2 * .pi
            cairo_move_to(cr, cos(a) * 6, sin(a) * 6); cairo_line_to(cr, cos(a) * 8.6, sin(a) * 8.6); cairo_stroke(cr)
        }
    }
}

/// Splits a polyline at fraction `t` of its length (for the self-drawing tick).
func trimmedPolyline(_ pts: [(Double, Double)], _ t: Double) -> [(Double, Double)] {
    guard pts.count > 1 else { return pts }
    var lens = [Double](), total = 0.0
    for i in 1..<pts.count {
        let l = hypot(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1); lens.append(l); total += l
    }
    var remain = total * min(1, max(0, t))
    var out = [pts[0]]
    for i in 1..<pts.count {
        if remain >= lens[i - 1] { out.append(pts[i]); remain -= lens[i - 1] }
        else {
            let k = lens[i - 1] > 0 ? remain / lens[i - 1] : 0
            out.append((pts[i - 1].0 + (pts[i].0 - pts[i - 1].0) * k, pts[i - 1].1 + (pts[i].1 - pts[i - 1].1) * k))
            break
        }
    }
    return out
}


func grouped(_ cr: Cr, alpha: Double, _ body: () -> Void) {
    if alpha >= 0.999 { body(); return }
    if alpha <= 0.002 { return }
    cairo_push_group(cr)
    body()
    cairo_pop_group_to_source(cr)
    cairo_paint_with_alpha(cr, alpha)
}

func setGradient(_ cr: Cr, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ stops: [(Double, Col)]) {
    let p = cairo_pattern_create_linear(x0, y0, x1, y1)!
    for (o, c) in stops { cairo_pattern_add_color_stop_rgba(p, o, c.r, c.g, c.b, c.a) }
    cairo_set_source(cr, p)
    cairo_pattern_destroy(p)
}
