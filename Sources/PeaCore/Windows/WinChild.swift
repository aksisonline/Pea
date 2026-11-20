#if os(Windows)
import Foundation
import WinSDK

// Native child-process launcher. Foundation's Process on Windows (as of Swift 6.1) never sets
// CREATE_NO_WINDOW (a console window flashes for every yt-dlp/ffmpeg launch from a GUI app) and
// TerminateProcess()es only the root process, orphaning ffmpeg and the yt-dlp.exe launcher's real child.
// This wrapper adds a Job Object (kill-on-close) and hidden windows.
// Constants are spelled out as literals so we don't depend on how WinSDK imports each macro.

private let kCreateSuspended: DWORD = 0x0000_0004
private let kCreateUnicodeEnvironment: DWORD = 0x0000_0400
private let kCreateNoWindow: DWORD = 0x0800_0000
private let kStartfUseStdHandles: DWORD = 0x0000_0100
private let kHandleFlagInherit: DWORD = 0x0000_0001
private let kGenericRead: DWORD = 0x8000_0000
private let kGenericWrite: DWORD = 0x4000_0000
private let kFileShareReadWrite: DWORD = 0x0000_0003
private let kOpenExisting: DWORD = 3
private let kInfinite: DWORD = 0xFFFF_FFFF
private let kJobKillOnClose: DWORD = 0x0000_2000

private let invalidHandle = UnsafeMutableRawPointer(bitPattern: -1)

protocol WinBoolLike { var asBool: Bool { get } }
extension WindowsBool: WinBoolLike { var asBool: Bool { boolValue } }
extension Bool: WinBoolLike { var asBool: Bool { self } }
extension Int32: WinBoolLike { var asBool: Bool { self != 0 } }
/// Win32 BOOL results, whichever Swift type the importer gives them.
@inline(__always) func ok(_ b: some WinBoolLike) -> Bool { b.asBool }

struct WinError: Error, CustomStringConvertible {
    let what: String
    let code: DWORD
    init(_ what: String) { self.what = what; code = GetLastError() }
    var description: String { "\(what) failed (Win32 error \(code))" }
}

final class WinChild: ChildProcess, @unchecked Sendable {
    /// Inheritable handles must not leak into a concurrently spawned child, so one spawn at a time.
    private static let spawnLock = NSLock()

    private var process: HANDLE?
    private var job: HANDLE?
    private var outRead: HANDLE?
    private var errRead: HANDLE?

    init(_ o: SpawnOptions) throws {
        Self.spawnLock.lock()
        defer { Self.spawnLock.unlock() }

        var sa = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                                     lpSecurityDescriptor: nil, bInheritHandle: true)
        var toClose: [HANDLE?] = []              // child-side ends, closed in the parent once the child has them
        var failed = true
        defer {
            for h in toClose { if let h { CloseHandle(h) } }
            if failed { closeAll() }
        }

        /// Pipe whose parent end is private and child end inheritable.
        func pipe(childReads: Bool) throws -> (parent: HANDLE?, child: HANDLE?) {
            var r: HANDLE? = nil, w: HANDLE? = nil
            guard ok(CreatePipe(&r, &w, &sa, 0)) else { throw WinError("CreatePipe") }
            let parent = childReads ? w : r
            SetHandleInformation(parent, kHandleFlagInherit, 0)
            return (parent, childReads ? r : w)
        }
        func nul() throws -> HANDLE? {
            let h: HANDLE? = "NUL".withCString(encodedAs: UTF16.self) {
                CreateFileW($0, kGenericRead | kGenericWrite, kFileShareReadWrite, &sa, kOpenExisting, 0x80, nil)
            }
            guard let h, h != invalidHandle else { throw WinError("open NUL") }
            return h
        }

        var si = STARTUPINFOW()
        si.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        si.dwFlags = kStartfUseStdHandles

        var stdinWrite: HANDLE? = nil
        if o.stdin != nil {
            let p = try pipe(childReads: true)
            stdinWrite = p.parent; si.hStdInput = p.child; toClose.append(p.child)
        } else { let n = try nul(); si.hStdInput = n; toClose.append(n) }

        if o.captureStdout {
            let p = try pipe(childReads: false)
            outRead = p.parent; si.hStdOutput = p.child; toClose.append(p.child)
        } else { let n = try nul(); si.hStdOutput = n; toClose.append(n) }

        if o.captureStderr {
            let p = try pipe(childReads: false)
            errRead = p.parent; si.hStdError = p.child; toClose.append(p.child)
        } else { let n = try nul(); si.hStdError = n; toClose.append(n) }

        var commandLine = Array(WindowsCommandLine.join([o.executable] + o.arguments).utf16) + [0]
        var env = WindowsCommandLine.environmentBlock(o.environment)
        var pi = PROCESS_INFORMATION()

        // Suspended so the process is in the job before it can start any child of its own.
        let flags = kCreateUnicodeEnvironment | kCreateNoWindow | kCreateSuspended
        let created: Bool = o.executable.withCString(encodedAs: UTF16.self) { app in
            commandLine.withUnsafeMutableBufferPointer { cmd in
                env.withUnsafeMutableBufferPointer { envp in
                    ok(CreateProcessW(app, cmd.baseAddress, nil, nil, true, flags, envp.baseAddress, nil, &si, &pi))
                }
            }
        }
        guard created else { throw WinError("CreateProcessW(\(o.executable))") }
        process = pi.hProcess

        // Best effort: without a job (very old Windows, or a restrictive parent job) fall back to plain TerminateProcess.
        if let j = CreateJobObjectW(nil, nil) {
            var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
            info.BasicLimitInformation.LimitFlags = kJobKillOnClose
            if ok(SetInformationJobObject(j, JobObjectExtendedLimitInformation, &info,
                                          DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))),
               ok(AssignProcessToJobObject(j, pi.hProcess)) {
                job = j
            } else { CloseHandle(j) }
        }
        ResumeThread(pi.hThread)
        CloseHandle(pi.hThread)
        failed = false

        if let stdin = o.stdin, let w = stdinWrite {
            let box = HandleBox(w)
            DispatchQueue.global().async {
                stdin.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        var n: DWORD = 0
                        let chunk = DWORD(min(raw.count - offset, 1 << 16))
                        guard ok(WriteFile(box.h, raw.baseAddress! + offset, chunk, &n, nil)), n > 0 else { break }
                        offset += Int(n)
                    }
                }
                CloseHandle(box.h)
            }
        }
    }

    private final class HandleBox: @unchecked Sendable {
        let h: HANDLE?
        init(_ h: HANDLE?) { self.h = h }
    }

    private func closeAll() {
        for h in [outRead, errRead, job, process] { if let h { CloseHandle(h) } }
        outRead = nil; errRead = nil; job = nil; process = nil
    }

    deinit { closeAll() }   // closing the job handle also kills anything still running in it

    private func read(_ h: HANDLE?) -> Data {
        guard let h else { return Data() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var n: DWORD = 0
        let good = buffer.withUnsafeMutableBytes { ok(ReadFile(h, $0.baseAddress, DWORD($0.count), &n, nil)) }
        // ERROR_BROKEN_PIPE (109) is the normal EOF once every writer has exited.
        return good && n > 0 ? Data(buffer[0..<Int(n)]) : Data()
    }

    func readStdout() -> Data { read(outRead) }
    func readStderr() -> Data { read(errRead) }

    func wait() -> Int32 {
        guard let p = process else { return -1 }
        WaitForSingleObject(p, kInfinite)
        var code: DWORD = 0
        GetExitCodeProcess(p, &code)
        return Int32(bitPattern: code)
    }

    func terminate() {
        if let j = job { TerminateJobObject(j, 1) }
        else if let p = process { TerminateProcess(p, 1) }
    }
}
#endif
