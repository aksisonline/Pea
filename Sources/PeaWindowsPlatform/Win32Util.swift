#if os(Windows)
import WinSDK

protocol WinBoolLike { var asBool: Bool { get } }
extension WindowsBool: WinBoolLike { var asBool: Bool { boolValue } }
extension Bool: WinBoolLike { var asBool: Bool { self } }
extension Int32: WinBoolLike { var asBool: Bool { self != 0 } }
/// Win32 BOOL results, whichever Swift type the importer gives them.
@inline(__always) func ok(_ b: some WinBoolLike) -> Bool { b.asBool }
#endif
