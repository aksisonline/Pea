#if os(Windows)
import PeaCore
import Foundation
import WinSDK

/// Drag a finished file out of the window with the shell's own drag-and-drop (the same data object Explorer uses),
/// instead of GTK 4's Windows drag source, which crashes (null deref inside gtk-4-1.dll) when a drag starts.
public enum WindowsDrag {
    private static let dropEffectMove: DWORD = 2

    /// Runs the (modal) drag. Returns true when the file was moved away from `url`.
    @MainActor
    public static func dragOut(_ url: URL) -> Bool {
        _ = OleInitialize(nil)                       // GTK normally did this already: S_FALSE then, harmless
        let path = Platform.nativePath(url)
        var pidl: UnsafeMutablePointer<ITEMIDLIST>? = nil
        var attrs: ULONG = 0
        let parsed = path.withCString(encodedAs: UTF16.self) { SHParseDisplayName($0, nil, &pidl, 0, &attrs) }
        guard parsed == S_OK, let item = pidl else { return false }
        defer { CoTaskMemFree(UnsafeMutableRawPointer(item)) }

        var iid = GUID(Data1: 0x0000010e, Data2: 0, Data3: 0, Data4: (0xC0, 0, 0, 0, 0, 0, 0, 0x46))   // IID_IDataObject
        var dataObject: UnsafeMutableRawPointer? = nil
        var items: [UnsafePointer<ITEMIDLIST>?] = [UnsafePointer(item)]
        let made = items.withUnsafeMutableBufferPointer { buf in
            SHCreateDataObject(nil, 1, buf.baseAddress, nil, &iid, &dataObject)
        }
        guard made == S_OK, let raw = dataObject else { return false }
        let data = raw.assumingMemoryBound(to: IDataObject.self)
        defer { _ = data.pointee.lpVtbl.pointee.Release(data) }

        let owner = GetActiveWindow() ?? GetForegroundWindow()
        var effect: DWORD = 0
        _ = SHDoDragDrop(owner, data, nil, dropEffectMove, &effect)
        // Explorer reports an optimised move as "no effect", so also check that the file is gone.
        return effect == dropEffectMove || !FileManager.default.fileExists(atPath: path)
    }
}
#endif
