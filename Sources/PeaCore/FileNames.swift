import Foundation

/// Naming and moving downloaded files safely on every OS (pure logic: unit-tested on Linux).
public enum FileNames {
    private static let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    private static let reserved: Set<String> =
        Set(["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })

    /// A file name that is legal on this OS. `dirLength` is the length of the folder path it will live in.
    /// Always: no path separators / reserved punctuation / control characters, at most 255 UTF-8 bytes
    /// (a POSIX limit that Windows also respects in practice). Windows rules (default on Windows):
    /// no trailing dots or spaces, no device names (CON, NUL, COM1 … with or without an extension),
    /// and the full path kept under MAX_PATH (260).
    public static func sanitize(_ raw: String, fallback: String = "download", dirLength: Int = 0,
                                windows: Bool = Platform.isWindows) -> String {
        var name = String(raw.map { ch -> Character in
            forbidden.contains(ch) || ch.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } ? "-" : ch
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        if windows { while let l = name.last, l == "." || l == " " { name.removeLast() } }
        if name.isEmpty || name.allSatisfy({ $0 == "-" || $0 == "." }) { name = fallback }

        // Split so truncation keeps the extension.
        let ns = name as NSString
        var ext = ns.pathExtension, base = ns.deletingPathExtension
        if ext.count > 16 { base = name; ext = "" }
        if base.isEmpty { base = name; ext = "" }

        var limitBytes = 255 - 12                       // headroom for a " (n)" uniqueness suffix
        if windows { limitBytes = min(limitBytes, max(40, 259 - 12 - dirLength - 1)) }
        let extBytes = ext.isEmpty ? 0 : ext.utf8.count + 1
        while base.utf8.count + extBytes > limitBytes, base.count > 1 { base.removeLast() }

        if windows {
            while let l = base.last, l == "." || l == " " { base.removeLast() }
            if base.isEmpty { base = fallback }
            // Device names are reserved even with an extension ("nul.txt"), and "con " too.
            let stem = base.split(separator: ".", maxSplits: 1).first.map(String.init) ?? base
            if reserved.contains(stem.trimmingCharacters(in: .whitespaces).uppercased()) { base = "_" + base }
        }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// Moves a finished temp file into place. `moveItem` can fail across volumes (temp on C:, Downloads on D: or
    /// redirected by OneDrive) on some Foundation versions, so fall back to copy + delete.
    public static func move(_ src: URL, to dest: URL) throws {
        let fm = FileManager.default
        do { try fm.moveItem(at: src, to: dest) }
        catch {
            do { try fm.copyItem(at: src, to: dest) }
            catch { try? fm.removeItem(at: dest); throw error }
            try? fm.removeItem(at: src)
        }
    }

    /// `name`, or `name (1)`, `name (2)` … so nothing is overwritten.
    public static func unique(_ name: String, in dir: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 1
        while exists(url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
