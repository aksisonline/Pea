#if os(Windows)
import DAllCore
import Foundation
import WinSDK

/// System clipboard through the Win32 API (CF_UNICODETEXT).
public final class WindowsClipboard: Clipboard {
    public init() {}

    private static let cfUnicodeText: UINT = 13            // CF_UNICODETEXT
    private static let gmemMoveable: UINT = 0x0002         // GMEM_MOVEABLE

    /// `GetClipboardSequenceNumber` increments on every change to the clipboard: exact and nearly free to poll.
    public var changeToken: Int { Int(GetClipboardSequenceNumber()) }

    /// OpenClipboard fails while another app holds it (clipboard managers, RDP); retry briefly.
    private func open() -> Bool {
        for _ in 0..<10 {
            if ok(OpenClipboard(GetDesktopWindow())) { return true }   // see write(): a non-nil owner is required to set data
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    public func read() -> String? {
        guard ok(IsClipboardFormatAvailable(Self.cfUnicodeText)), open() else { return nil }
        defer { CloseClipboard() }
        guard let handle = GetClipboardData(Self.cfUnicodeText), let ptr = GlobalLock(handle) else { return nil }
        defer { GlobalUnlock(handle) }
        // The block is NUL-terminated UTF-16 owned by the clipboard; copy it out while locked.
        let text = String(decodingCString: ptr.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
        return text.isEmpty ? nil : text
    }

    public func write(_ text: String) {
        // With a NULL owner window, EmptyClipboard() makes SetClipboardData fail; the desktop window is the usual stand-in.
        guard open() else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let units = Array(text.utf16) + [0]
        let bytes = units.count * MemoryLayout<UInt16>.size
        guard let mem = GlobalAlloc(Self.gmemMoveable, SIZE_T(bytes)), let dst = GlobalLock(mem) else { return }
        units.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(mem)
        // On success the system owns `mem`; on failure we must free it.
        if SetClipboardData(Self.cfUnicodeText, mem) == nil { GlobalFree(mem) }
    }
}
#endif
