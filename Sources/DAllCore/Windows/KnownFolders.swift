#if os(Windows)
import Foundation
import WinSDK

enum KnownFolders {
    /// The user's real Downloads folder (honours relocation, e.g. to D:\ or OneDrive), or nil.
    static func downloads() -> String? {
        // FOLDERID_Downloads {374DE290-123F-4565-9164-39C4925E467B}, spelled out so we don't depend on linking uuid.lib.
        var id = GUID(Data1: 0x374D_E290, Data2: 0x123F, Data3: 0x4565,
                      Data4: (0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B))
        var path: PWSTR? = nil
        defer { if let path { CoTaskMemFree(path) } }
        guard SHGetKnownFolderPath(&id, 0, nil, &path) == 0 /* S_OK */, let path else { return nil }
        let s = String(decodingCString: path, as: UTF16.self)
        return s.isEmpty ? nil : s
    }
}
#endif
