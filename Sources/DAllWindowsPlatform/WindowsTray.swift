#if os(Windows)
import DAllCore
import Foundation
import WinSDK

/// Notification-area icon (Shell_NotifyIconW). Create and `install()` it on the thread that runs the UI's message
/// loop (the main thread): the shell delivers clicks as window messages to a hidden window owned by this object,
/// so any standard GetMessage/DispatchMessage pump (every Win32/WinUI shell has one) drives it.
@MainActor
public final class WindowsTray: TrayIcon {
    public var onToggle: (() -> Void)?
    public var onSecondaryClick: (() -> Void)?
    public var isLit = false { didSet { if isLit != oldValue { refresh() } } }
    public var toolTip = "D-All" { didSet { if toolTip != oldValue { refresh() } } }

    private var hwnd: HWND?
    private var installed = false
    private var litIcon: HICON?
    private var idleIcon: HICON?
    fileprivate var taskbarCreated: UINT = 0

    private static let callbackMessage: UINT = 0x8000 + 1          // WM_APP + 1
    private static let wmLButtonUp: UInt = 0x0202, wmRButtonUp: UInt = 0x0205, wmContextMenu: UInt = 0x007B
    private static let nimAdd: DWORD = 0, nimModify: DWORD = 1, nimDelete: DWORD = 2
    private static let nifMessage: UINT = 0x1, nifIcon: UINT = 0x2, nifTip: UINT = 0x4
    private static let className = "DAllTrayWindow"

    public init() {}

    public func install() {
        guard !installed else { return }
        guard createWindow() else { return }
        litIcon = Self.makeIcon(lit: true)
        idleIcon = Self.makeIcon(lit: false)
        taskbarCreated = "TaskbarCreated".withCString(encodedAs: UTF16.self) { RegisterWindowMessageW($0) }
        Self.current = self
        installed = notify(Self.nimAdd)
    }

    public func remove() {
        if installed { _ = notify(Self.nimDelete); installed = false }
        if let hwnd { DestroyWindow(hwnd) }
        hwnd = nil
        for i in [litIcon, idleIcon] { if let i { DestroyIcon(i) } }
        litIcon = nil; idleIcon = nil
        if Self.current === self { Self.current = nil }
    }

    private func refresh() { if installed { _ = notify(Self.nimModify) } }

    // MARK: Shell_NotifyIconW

    private func notify(_ message: DWORD) -> Bool {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = hwnd
        data.uID = 1
        data.uFlags = Self.nifMessage | Self.nifIcon | Self.nifTip
        data.uCallbackMessage = Self.callbackMessage
        data.hIcon = isLit ? litIcon : idleIcon
        // szTip is a fixed WCHAR[128] (a Swift tuple): copy the UTF-16 in, truncated, always NUL-terminated.
        withUnsafeMutableBytes(of: &data.szTip) { raw in
            let buf = raw.bindMemory(to: UInt16.self)
            let units = Array(toolTip.utf16.prefix(buf.count - 1))
            for (i, u) in units.enumerated() { buf[i] = u }
            buf[units.count] = 0
        }
        return ok(Shell_NotifyIconW(message, &data))
    }

    // MARK: Hidden window

    private func createWindow() -> Bool {
        let hInstance = GetModuleHandleW(nil)
        let created: HWND? = Self.className.withCString(encodedAs: UTF16.self) { name in
            var wc = WNDCLASSW()
            wc.lpfnWndProc = trayWindowProc
            wc.hInstance = hInstance
            wc.lpszClassName = name
            RegisterClassW(&wc)      // fails harmlessly with "class already exists" on a second install
            // A normal top-level window that is never shown (avoids relying on the HWND_MESSAGE macro import).
            return CreateWindowExW(0, name, name, 0, 0, 0, 0, 0, nil, nil, hInstance, nil)
        }
        hwnd = created
        return created != nil
    }

    fileprivate static weak var current: WindowsTray?

    fileprivate func handle(_ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) {
        if msg == Self.callbackMessage {
            switch UInt(bitPattern: lParam) & 0xFFFF {     // version-0 callback: lParam is the mouse message
            case Self.wmLButtonUp: onToggle?()
            case Self.wmRButtonUp, Self.wmContextMenu: onSecondaryClick?()
            default: break
            }
        } else if msg == taskbarCreated, taskbarCreated != 0 {
            installed = notify(Self.nimAdd)                 // Explorer restarted: the icon must be re-added
        }
    }

    // MARK: Icons (drawn in memory: no .ico resource to ship)

    private static func makeIcon(lit: Bool) -> HICON? {
        let size = 32
        var pixels = TrayGlyph.bgra(size: size, lit: lit)
        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = LONG(size)
        bmi.bmiHeader.biHeight = -LONG(size)               // top-down
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = 0                    // BI_RGB
        var bits: UnsafeMutableRawPointer? = nil
        guard let color = CreateDIBSection(nil, &bmi, 0 /* DIB_RGB_COLORS */, &bits, nil, 0), let bits else { return nil }
        pixels.withUnsafeBytes { bits.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        // With a 32-bit alpha colour bitmap the mask is ignored but must exist.
        guard let mask = CreateBitmap(Int32(size), Int32(size), 1, 1, nil) else { DeleteObject(color); return nil }
        var info = ICONINFO(fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color)
        let icon = CreateIconIndirect(&info)
        DeleteObject(color); DeleteObject(mask)
        return icon
    }
}

/// Window procedure (a C function pointer: cannot capture, so it finds the tray through a static).
private func trayWindowProc(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    MainActor.assumeIsolated { WindowsTray.current?.handle(msg, wParam, lParam) }
    return DefWindowProcW(hwnd, msg, wParam, lParam)
}
#endif
