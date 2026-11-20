import CGTK
import PeaCore
import Foundation

/// A Cairo image surface that cleans up after itself.
final class Surf {
    let s: OpaquePointer
    let w: Int, h: Int
    init(_ s: OpaquePointer, w: Int, h: Int) { self.s = s; self.w = w; self.h = h }
    deinit { cairo_surface_destroy(s) }

    /// From straight-alpha RGBA/RGB bytes (GdkPixbuf layout).
    static func fromPixels(_ px: [UInt8], w: Int, h: Int, channels: Int, stride: Int) -> Surf? {
        guard let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(w), Int32(h)),
              cairo_surface_status(s) == CAIRO_STATUS_SUCCESS else { return nil }
        cairo_surface_flush(s)
        let dst = cairo_image_surface_get_data(s)!, ds = Int(cairo_image_surface_get_stride(s))
        for y in 0..<h {
            for x in 0..<w {
                let i = y * stride + x * channels, o = y * ds + x * 4
                let a = channels == 4 ? Int(px[i + 3]) : 255
                dst[o] = UInt8(Int(px[i + 2]) * a / 255)
                dst[o + 1] = UInt8(Int(px[i + 1]) * a / 255)
                dst[o + 2] = UInt8(Int(px[i]) * a / 255)
                dst[o + 3] = UInt8(a)
            }
        }
        cairo_surface_mark_dirty(s)
        return Surf(s, w: w, h: h)
    }
}

enum Pix {
    /// Decodes any image GdkPixbuf understands.
    static func decode(_ data: Data) -> OpaquePointer? {
        guard !data.isEmpty, let loader = gdk_pixbuf_loader_new() else { return nil }
        defer { g_object_unref(Ptr(loader)) }
        let ok: Bool = data.withUnsafeBytes { buf in
            gdk_pixbuf_loader_write(loader, buf.bindMemory(to: UInt8.self).baseAddress, gsize(buf.count), nil) != 0
        }
        _ = gdk_pixbuf_loader_close(loader, nil)
        guard ok, let pb = gdk_pixbuf_loader_get_pixbuf(loader) else { return nil }
        return OpaquePointer(g_object_ref(Ptr(pb)))
    }

    static func size(_ pb: OpaquePointer) -> (Int, Int) { (Int(gdk_pixbuf_get_width(pb)), Int(gdk_pixbuf_get_height(pb))) }

    /// Centre square crop scaled to `side`.
    static func coverSquare(_ pb: OpaquePointer, side: Int, hyper: Bool = true) -> OpaquePointer? {
        let (w, h) = size(pb), m = min(w, h)
        guard m > 0, let sub = gdk_pixbuf_new_subpixbuf(pb, Int32((w - m) / 2), Int32((h - m) / 2), Int32(m), Int32(m)) else { return nil }
        defer { g_object_unref(Ptr(sub)) }
        return gdk_pixbuf_scale_simple(sub, Int32(side), Int32(side), hyper ? GDK_INTERP_HYPER : GDK_INTERP_BILINEAR)
    }

    static func bytes(_ pb: OpaquePointer) -> (px: [UInt8], w: Int, h: Int, ch: Int, stride: Int) {
        let w = Int(gdk_pixbuf_get_width(pb)), h = Int(gdk_pixbuf_get_height(pb))
        let ch = Int(gdk_pixbuf_get_n_channels(pb)), stride = Int(gdk_pixbuf_get_rowstride(pb))
        let p = gdk_pixbuf_get_pixels(pb)!
        return (Array(UnsafeBufferPointer(start: p, count: stride * (h - 1) + w * ch)), w, h, ch, stride)
    }

    /// 16x16 RGB24 sample for `Artwork.palette`; replaces the ffmpeg-based default sampler.
    static func sample(_ data: Data) -> [UInt8]? {
        guard let pb = decode(data) else { return nil }
        defer { g_object_unref(Ptr(pb)) }
        guard let small = gdk_pixbuf_scale_simple(pb, 16, 16, GDK_INTERP_BILINEAR) else { return nil }
        defer { g_object_unref(Ptr(small)) }
        let b = bytes(small)
        var out = [UInt8]()
        for y in 0..<16 { for x in 0..<16 { let i = y * b.stride + x * b.ch; out += [b.px[i], b.px[i + 1], b.px[i + 2]] } }
        return out
    }
}

/// Decoded artwork, prepared once for drawing: a sharp square (hint bubble) and a blurred,
/// saturated one (the glassy circle fill).
final class ArtImage {
    let sharp: Surf
    let glass: Surf

    init?(_ data: Data) {
        guard let pb = Pix.decode(data) else { return nil }
        defer { g_object_unref(Ptr(pb)) }
        guard let sq = Pix.coverSquare(pb, side: 160) else { return nil }
        defer { g_object_unref(Ptr(sq)) }
        let b = Pix.bytes(sq)
        guard let sharp = Surf.fromPixels(b.px, w: b.w, h: b.h, channels: b.ch, stride: b.stride) else { return nil }
        self.sharp = sharp

        // Glass: tiny version, saturate, box-blur ×3 → smooth wash when scaled up.
        guard let tiny = Pix.coverSquare(pb, side: 48) else { return nil }
        defer { g_object_unref(Ptr(tiny)) }
        let t = Pix.bytes(tiny)
        let n = t.w * t.h
        var f = [Float](repeating: 0, count: n * 3)
        for y in 0..<t.h {
            for x in 0..<t.w {
                let i = y * t.stride + x * t.ch, o = (y * t.w + x) * 3
                let r = Float(t.px[i]), g = Float(t.px[i + 1]), bl = Float(t.px[i + 2])
                let l = 0.299 * r + 0.587 * g + 0.114 * bl
                f[o] = min(255, max(0, l + (r - l) * 1.5)); f[o + 1] = min(255, max(0, l + (g - l) * 1.5)); f[o + 2] = min(255, max(0, l + (bl - l) * 1.5))
            }
        }
        for _ in 0..<3 { f = Self.boxBlur(f, w: t.w, h: t.h, radius: 4) }
        let rgb = f.map { UInt8(min(255, max(0, $0))) }
        guard let glass = Surf.fromPixels(rgb, w: t.w, h: t.h, channels: 3, stride: t.w * 3) else { return nil }
        self.glass = glass
    }

    private static func boxBlur(_ src: [Float], w: Int, h: Int, radius r: Int) -> [Float] {
        var tmp = src, out = src
        for y in 0..<h {                         // horizontal
            for x in 0..<w {
                var acc = [Float](repeating: 0, count: 3)
                for k in -r...r { let xx = min(w - 1, max(0, x + k)); for c in 0..<3 { acc[c] += src[(y * w + xx) * 3 + c] } }
                for c in 0..<3 { tmp[(y * w + x) * 3 + c] = acc[c] / Float(2 * r + 1) }
            }
        }
        for y in 0..<h {                         // vertical
            for x in 0..<w {
                var acc = [Float](repeating: 0, count: 3)
                for k in -r...r { let yy = min(h - 1, max(0, y + k)); for c in 0..<3 { acc[c] += tmp[(yy * w + x) * 3 + c] } }
                for c in 0..<3 { out[(y * w + x) * 3 + c] = acc[c] / Float(2 * r + 1) }
            }
        }
        return out
    }
}

private final class Failed {}

extension Artwork {
    /// Cached decoded form; nil when the bytes aren't an image we can read.
    var image: ArtImage? {
        if let i = native as? ArtImage { return i }
        if native is Failed { return nil }
        if let i = ArtImage(data) { native = i; return i }
        native = Failed()
        return nil
    }
}

/// Paints `s` scaled to the box (x, y, w, h) with smooth filtering.
func paintSurface(_ cr: Cr, _ s: Surf, x: Double, y: Double, w: Double, h: Double, alpha: Double = 1) {
    cairo_save(cr)
    cairo_rectangle(cr, x, y, w, h); cairo_clip(cr)
    cairo_translate(cr, x, y)
    cairo_scale(cr, w / Double(s.w), h / Double(s.h))
    cairo_set_source_surface(cr, s.s, 0, 0)
    if let p = cairo_get_source(cr) {
        cairo_pattern_set_filter(p, CAIRO_FILTER_BILINEAR)
        cairo_pattern_set_extend(p, CAIRO_EXTEND_PAD)
    }
    cairo_paint_with_alpha(cr, alpha)
    cairo_restore(cr)
}
