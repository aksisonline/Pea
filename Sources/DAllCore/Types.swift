import Foundation

public enum Kind: Sendable { case video, audio }

public enum Quality: String, CaseIterable, Sendable {
    case original = "Original"
    case high = "High Quality"
    case small = "Save Space"
}

public enum AudioFormat: String, CaseIterable, Sendable {
    case opus = "Opus", mp3 = "MP3", wav = "WAV"
}

/// One step of first-run setup. The platform decides which steps exist and how each is carried out;
/// the UI only needs these labels (`icon` is a neutral key each UI maps to its own symbol).
public struct SetupStep: Hashable, Sendable {
    public let id: String
    public let title: String
    public let reason: String
    public let icon: String
    public let action: String          // "Allow" -> "Click to allow"

    public init(id: String, title: String, reason: String, icon: String, action: String) {
        self.id = id; self.title = title; self.reason = reason; self.icon = icon; self.action = action
    }
}

public enum Phase {
    case setup(SetupStep)
    case ready                        // the "Ready!" beat after setup
    case idle
    case kind(URL)
    case quality(URL, Kind)
    case working
    case done(URL)
    case failed(String)
}

/// Where a link comes from, for the badge icon and routing (audio-only services skip the Video/Audio step).
public struct Source: Equatable, Sendable {
    public let name: String
    /// Neutral icon key (`music`, `waveform`, `video`, `camera`, `chat`, `pin`, `globe`); each UI maps it.
    public let icon: String
    public let audioOnly: Bool

    public var isKnown: Bool { icon != "globe" }
    public var isSpotify: Bool { name == "Spotify" }

    public static func of(_ url: URL) -> Source {
        let h = (url.host ?? "").lowercased()
        func has(_ d: String...) -> Bool { d.contains { h == $0 || h.hasSuffix("." + $0) } }
        if has("spotify.com") { return Source(name: "Spotify", icon: "music", audioOnly: true) }
        if has("soundcloud.com") { return Source(name: "SoundCloud", icon: "waveform", audioOnly: true) }
        if has("youtube.com", "youtu.be") { return Source(name: "YouTube", icon: "video", audioOnly: false) }
        if has("tiktok.com") { return Source(name: "TikTok", icon: "video", audioOnly: false) }
        if has("instagram.com") { return Source(name: "Instagram", icon: "camera", audioOnly: false) }
        if has("twitter.com", "x.com") { return Source(name: "X", icon: "chat", audioOnly: false) }
        if has("pinterest.com") { return Source(name: "Pinterest", icon: "pin", audioOnly: false) }
        return Source(name: h.hasPrefix("www.") ? String(h.dropFirst(4)) : h, icon: "globe", audioOnly: false)
    }
}

public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    public var hsb: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    public static func fromHSB(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        let c = v * s, x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h * 6) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGB(r + m, g + m, b + m)
    }
}

/// Artwork bytes plus the colours pulled from them, computed once. `native` lets a UI cache its own
/// decoded image (NSImage, GdkPixbuf, …) on the instance.
public final class Artwork: Equatable, @unchecked Sendable {
    public let data: Data
    public let palette: [RGB]
    public var native: AnyObject?

    public init(data: Data, palette: [RGB]) { self.data = data; self.palette = palette }

    public static func == (a: Artwork, b: Artwork) -> Bool { a === b }

    /// Decodes `data` into a 16×16 RGB sample. Default uses ffmpeg (already a requirement); a UI may
    /// replace it with something native.
    nonisolated(unsafe) public static var sampler: @Sendable (Data) async -> [UInt8]? = { await Tools.sampleImage($0) }

    public static func make(_ data: Data) async -> Artwork? {
        guard !data.isEmpty else { return nil }
        let pixels = await sampler(data) ?? []
        return Artwork(data: data, palette: dominantColors(pixels))
    }

    /// Up to three dominant hues (by saturation-weighted area), ordered round the colour wheel.
    /// `pixels` is RGB24; anything else yields no palette and the UI falls back to its accent colour.
    static func dominantColors(_ pixels: [UInt8]) -> [RGB] {
        guard pixels.count >= 3 else { return [] }
        var buckets = [(r: Double, g: Double, b: Double, w: Double)](repeating: (0, 0, 0, 0), count: 8)
        for i in stride(from: 0, to: pixels.count - 2, by: 3) {
            let c = RGB(Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
            let (h, s, v) = c.hsb
            guard s > 0.15, v > 0.15 else { continue }
            let k = min(7, Int(h * 8)), wt = s * v
            buckets[k].r += c.r * wt; buckets[k].g += c.g * wt; buckets[k].b += c.b * wt; buckets[k].w += wt
        }
        let total = buckets.reduce(0) { $0 + $1.w }
        return buckets.enumerated()
            .filter { $0.element.w > max(0.0001, total * 0.12) }
            .sorted { $0.element.w > $1.element.w }
            .prefix(3)
            .sorted { $0.offset < $1.offset }
            .map { _, b in
                let (h, s, v) = RGB(b.r / b.w, b.g / b.w, b.b / b.w).hsb
                return RGB.fromHSB(h, min(1, s * 1.2), max(v, 0.85))
            }
    }
}

public struct Meta {
    public var title: String?
    public var art: Artwork?
    public init(title: String? = nil, art: Artwork? = nil) { self.title = title; self.art = art }
}

/// A link on the clipboard, with whatever we've learned about it.
public struct Suggestion: Equatable {
    public let url: URL
    public var title: String?
    public var art: Artwork?
    public let source: Source
    public init(url: URL, title: String?, art: Artwork?, source: Source) {
        self.url = url; self.title = title; self.art = art; self.source = source
    }
}
