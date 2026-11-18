import Foundation

/// Tiny key-value store for the few settings the core keeps. macOS/Linux keep using UserDefaults
/// (so existing users keep their choices); Windows uses a JSON file because swift-corelibs-foundation's
/// UserDefaults on Windows is backed by CFPreferences with no documented, tested persistence story there.
public protocol SettingsStore: AnyObject, Sendable {
    func string(_ key: String) -> String?
    func bool(_ key: String) -> Bool
    func set(_ value: String?, for key: String)
    func set(_ value: Bool, for key: String)
}

public final class UserDefaultsSettings: SettingsStore, @unchecked Sendable {
    public init() {}
    public func string(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    public func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    public func set(_ value: String?, for key: String) { UserDefaults.standard.set(value, forKey: key) }
    public func set(_ value: Bool, for key: String) { UserDefaults.standard.set(value, forKey: key) }
}

/// Flat JSON object on disk, written atomically (temp file + replace). Tolerates a missing or corrupt file.
public final class JSONFileSettings: SettingsStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { values = obj }
    }

    public func string(_ key: String) -> String? { lock.withLock { values[key] as? String } }
    public func bool(_ key: String) -> Bool { lock.withLock { values[key] as? Bool ?? false } }
    public func set(_ value: String?, for key: String) { store(key, value) }
    public func set(_ value: Bool, for key: String) { store(key, value) }

    private func store(_ key: String, _ value: Any?) {
        lock.withLock {
            values[key] = value
            guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted]) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

public enum AppSettings {
    nonisolated(unsafe) public static var store: SettingsStore = {
        #if os(Windows)
        return JSONFileSettings(url: Platform.supportDirectory.appendingPathComponent("settings.json"))
        #else
        return UserDefaultsSettings()
        #endif
    }()
}
