import Foundation

/// What to run. Arguments are passed verbatim: no shell, no re-parsing on any OS.
struct SpawnOptions {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var stdin: Data?
    var captureStdout = true
    var captureStderr = false
}

/// A running child process with blocking pipe reads (call them from their own threads).
/// `terminate()` must stop the whole process tree: yt-dlp spawns ffmpeg, and the Windows
/// yt-dlp.exe launcher re-spawns itself, so killing only the root would leave work running.
protocol ChildProcess: AnyObject, Sendable {
    /// Blocks until data is available; empty `Data` means EOF.
    func readStdout() -> Data
    func readStderr() -> Data
    /// Blocks until the root process exits; returns its exit status.
    func wait() -> Int32
    func terminate()
}

enum ChildProcessFactory {
    static func spawn(_ o: SpawnOptions) throws -> ChildProcess {
        #if os(Windows)
        return try WinChild(o)
        #else
        return try FoundationChild(o)
        #endif
    }
}

/// POSIX implementation on Foundation's Process.
final class FoundationChild: ChildProcess, @unchecked Sendable {
    private let process = Process()
    private let outHandle: FileHandle?
    private let errHandle: FileHandle?

    init(_ o: SpawnOptions) throws {
        process.executableURL = URL(fileURLWithPath: o.executable)
        process.arguments = o.arguments
        process.environment = o.environment
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = o.captureStdout ? out : FileHandle.nullDevice
        process.standardError = o.captureStderr ? err : FileHandle.nullDevice
        process.standardInput = o.stdin == nil ? FileHandle.nullDevice : inPipe
        outHandle = o.captureStdout ? out.fileHandleForReading : nil
        errHandle = o.captureStderr ? err.fileHandleForReading : nil
        try process.run()
        if let stdin = o.stdin {
            // Feed stdin from its own thread so a full pipe can't deadlock the reads.
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }
    }

    func readStdout() -> Data { outHandle?.availableData ?? Data() }
    func readStderr() -> Data { errHandle?.availableData ?? Data() }
    func wait() -> Int32 { process.waitUntilExit(); return process.terminationStatus }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Windows command-line construction (CreateProcessW takes one string; the child's C runtime splits it back).
/// Pure string logic, so it is unit-tested on every OS. Rules: "Everyone quotes command line arguments the
/// wrong way" (Colascione) / MS C runtime argv parsing.
public enum WindowsCommandLine {
    public static func quote(_ arg: String) -> String {
        if !arg.isEmpty, !arg.contains(where: { " \t\n\u{0B}\"".contains($0) }) { return arg }
        var out = "\""
        var backslashes = 0
        for ch in arg.unicodeScalars {
            if ch == "\\" {
                backslashes += 1
            } else if ch == "\"" {
                out += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
                backslashes = 0
            } else {
                out += String(repeating: "\\", count: backslashes)
                backslashes = 0
                out.unicodeScalars.append(ch)
            }
        }
        out += String(repeating: "\\", count: backslashes * 2) + "\""   // so a trailing \ can't escape the closing quote
        return out
    }

    public static func join(_ args: [String]) -> String { args.map(quote).joined(separator: " ") }

    /// Reference splitter (MS C runtime rules) used by tests to prove `quote` round-trips.
    public static func split(_ line: String) -> [String] {
        var args: [String] = []
        var cur = "", started = false, inQuotes = false
        let s = Array(line.unicodeScalars)
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\\" {
                var n = 0
                while i < s.count, s[i] == "\\" { n += 1; i += 1 }
                if i < s.count, s[i] == "\"" {
                    cur += String(repeating: "\\", count: n / 2); started = true
                    if n % 2 == 1 { cur += "\""; i += 1 }     // escaped quote; otherwise the quote is handled next loop
                } else { cur += String(repeating: "\\", count: n); started = true }
                continue
            }
            if c == "\"" { inQuotes.toggle(); started = true }
            else if (c == " " || c == "\t") && !inQuotes {
                if started { args.append(cur); cur = ""; started = false }
            } else { cur.unicodeScalars.append(c); started = true }
            i += 1
        }
        if started { args.append(cur) }
        return args
    }

    /// The Windows environment block: `K=V\0K=V\0\0`, sorted case-insensitively as the docs recommend.
    public static func environmentBlock(_ env: [String: String]) -> [UInt16] {
        var units: [UInt16] = []
        for k in env.keys.sorted(by: { $0.uppercased() < $1.uppercased() }) {
            units += Array((k + "=" + env[k]!).utf16) + [0]
        }
        if units.isEmpty { units.append(0) }
        units.append(0)
        return units
    }
}
