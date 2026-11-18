import CGTK
import DAllCore
import Foundation

/// The picture shown for a finished file: a real thumbnail when we can make one (images directly,
/// video frames / cover art through ffmpeg), otherwise a generic file icon with the extension.
@MainActor
final class FileThumb {
    let url: URL
    private(set) var surf: Surf?
    var onReady: (() -> Void)?

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "tif", "tiff", "avif", "ico"]
    static let mediaExts: Set<String> = ["mp4", "mkv", "webm", "mov", "avi", "m4v", "flv", "ts", "mp3", "m4a", "opus", "ogg",
                                         "flac", "wav", "aac", "wma", "oga"]

    init(url: URL) {
        self.url = url
        let ext = url.pathExtension.lowercased()
        if Self.imageExts.contains(ext) {
            if let pb = gdk_pixbuf_new_from_file_at_scale(url.path, 240, 240, 1, nil) {
                let b = Pix.bytes(pb)
                surf = Surf.fromPixels(b.px, w: b.w, h: b.h, channels: b.ch, stride: b.stride)
                g_object_unref(Ptr(pb))
            }
        } else if Self.mediaExts.contains(ext), let ff = Tools.ffmpeg {
            let path = url.path
            DispatchQueue.global().async {
                let data = Self.frame(ff, path, seek: true) ?? Self.frame(ff, path, seek: false)
                guard let data, !data.isEmpty else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.adopt(data) } }
            }
        }
    }

    private func adopt(_ data: Data) {
        guard let pb = Pix.decode(data) else { return }
        defer { g_object_unref(Ptr(pb)) }
        let b = Pix.bytes(pb)
        surf = Surf.fromPixels(b.px, w: b.w, h: b.h, channels: b.ch, stride: b.stride)
        onReady?()
    }

    private nonisolated static func frame(_ ff: String, _ path: String, seek: Bool) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-v", "error"] + (seek ? ["-ss", "1"] : []) + ["-i", path, "-frames:v", "1",
                       "-vf", "scale=240:240:force_original_aspect_ratio=decrease", "-f", "image2pipe", "-vcodec", "png", "-"]
        p.environment = Tools.environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? d : nil
    }

    /// Draws the thumbnail (or the generic icon) fitted into a `box`-sized square centred on (cx, cy).
    func draw(_ cr: Cr, cx: Double, cy: Double, box: Double) {
        if let s = surf {
            let k = min(box / Double(s.w), box / Double(s.h)), w = Double(s.w) * k, h = Double(s.h) * k
            let x = cx - w / 2, y = cy - h / 2
            for i in 0..<4 {     // soft shadow
                roundRectPath(cr, x - Double(3 - i), y - Double(3 - i) + 2, w + Double(3 - i) * 2, h + Double(3 - i) * 2, 3 + Double(3 - i))
                cr.color(Col.black.alpha(0.09)); cairo_fill(cr)
            }
            paintSurface(cr, s, x: x, y: y, w: w, h: h)
        } else {
            Self.genericIcon(cr, cx: cx, cy: cy, box: box, ext: url.pathExtension)
        }
    }

    static func genericIcon(_ cr: Cr, cx: Double, cy: Double, box: Double, ext: String) {
        let w = box * 0.7, h = box * 0.9, x = cx - w / 2, y = cy - h / 2, fold = w * 0.3
        for i in 0..<4 {
            roundRectPath(cr, x - Double(3 - i), y - Double(3 - i) + 2, w + Double(3 - i) * 2, h + Double(3 - i) * 2, 6 + Double(3 - i))
            cr.color(Col.black.alpha(0.09)); cairo_fill(cr)
        }
        cairo_new_path(cr)
        cairo_move_to(cr, x + 5, y); cairo_line_to(cr, x + w - fold, y); cairo_line_to(cr, x + w, y + fold)
        cairo_line_to(cr, x + w, y + h - 5)
        cairo_arc(cr, x + w - 5, y + h - 5, 5, 0, .pi / 2)
        cairo_line_to(cr, x + 5, y + h)
        cairo_arc(cr, x + 5, y + h - 5, 5, .pi / 2, .pi)
        cairo_line_to(cr, x, y + 5)
        cairo_arc(cr, x + 5, y + 5, 5, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
        cr.color(Col(white: 0.93)); cairo_fill(cr)
        cairo_move_to(cr, x + w - fold, y); cairo_line_to(cr, x + w - fold, y + fold); cairo_line_to(cr, x + w, y + fold); cairo_close_path(cr)
        cr.color(Col(white: 0.78)); cairo_fill(cr)
        if !ext.isEmpty {
            drawTextMid(cr, String(ext.prefix(5)).uppercased(), cx: cx, cy: y + h * 0.62, size: min(15, w * 0.26), weight: .bold,
                        color: Col(white: 0.4))
        }
    }

    /// Renders the same picture into a drag-icon texture.
    func dragTexture(box: Double = 92) -> Ptr? {
        let side = Int(box) + 12
        guard let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(side), Int32(side)),
              let cr = cairo_create(s) else { return nil }
        draw(cr, cx: Double(side) / 2, cy: Double(side) / 2, box: box)
        cairo_destroy(cr)
        cairo_surface_flush(s)
        let stride = Int(cairo_image_surface_get_stride(s))
        let bytes = g_bytes_new(cairo_image_surface_get_data(s), gsize(stride * side))
        defer { g_bytes_unref(bytes); cairo_surface_destroy(s) }
        return Ptr(gdk_memory_texture_new(Int32(side), Int32(side), GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, gsize(stride)))
    }
}
