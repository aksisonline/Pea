import Foundation

/// A system tray / status icon the shell can drive. PeaCore never creates one; a platform module provides it
/// (Windows: `WindowsTray`). Typical wiring: `model.onChange = { tray.isLit = model.suggestion != nil }`,
/// `tray.onToggle = { window.toggle() }`.
@MainActor
public protocol TrayIcon: AnyObject {
    /// Lit = a downloadable link is on the clipboard.
    var isLit: Bool { get set }
    var toolTip: String { get set }
    /// Primary click: show or hide the window.
    var onToggle: (() -> Void)? { get set }
    /// Secondary click: show a menu (e.g. Quit) at the cursor, if the shell wants one.
    var onSecondaryClick: (() -> Void)? { get set }
    func install()
    func remove()
}

/// Pixels for a tray glyph, platform-neutral so it's testable: a filled circle (lit) or a ring (idle).
public enum TrayGlyph {
    /// BGRA, top-down, premultiplied alpha, `size`×`size`.
    public static func bgra(size: Int, lit: Bool, color: (r: UInt8, g: UInt8, b: UInt8) = (0xFF, 0x7A, 0x1A)) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let c = Double(size) / 2, outer = c - 1, inner = outer * 0.58
        for y in 0..<size {
            for x in 0..<size {
                let d = ((Double(x) + 0.5 - c) * (Double(x) + 0.5 - c) + (Double(y) + 0.5 - c) * (Double(y) + 0.5 - c)).squareRoot()
                // 1px antialiased edge on the outer circle (and inner edge for the ring).
                var a = max(0, min(1, outer - d + 0.5))
                if !lit { a = min(a, max(0, min(1, d - inner + 0.5))) }
                let v: (r: UInt8, g: UInt8, b: UInt8) = lit ? color : (0x9A, 0x9A, 0x9A)
                let i = (y * size + x) * 4
                px[i] = UInt8(Double(v.b) * a); px[i + 1] = UInt8(Double(v.g) * a)
                px[i + 2] = UInt8(Double(v.r) * a); px[i + 3] = UInt8(255 * a)
            }
        }
        return px
    }
}
