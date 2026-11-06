import Foundation
import Contracts

/// 设置持久化（文档 §6.7：UserDefaults，非敏感项；apiKey 走 Keychain）。
public protocol SettingsStoring: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

public final class UserDefaultsSettingsStore: SettingsStoring {
    public static let defaultKey = "settings.v1"

    private let defaults: UserDefaults
    public let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .default }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    public func rawData() -> Data? {
        defaults.data(forKey: key)
    }

    public func removeAll() {
        defaults.removeObject(forKey: key)
    }
}
