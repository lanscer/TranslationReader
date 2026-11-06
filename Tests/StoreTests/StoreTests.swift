import Testing
import Foundation
import Contracts
import Store

@Suite("Store 入口与设置/Keychain")
struct StoreEntryTests {
    @Test("Keychain 定位与 bundle id 一致")
    func keychainCoordinates() {
        #expect(Store.keychainService == "com.local.translationreader")
        #expect(Store.keychainAccount == "translate.apiKey")
    }

    @Test("历史记录可构造")
    func historyEntryConstruction() {
        let entry = HistoryEntry(id: "h1", createdAt: 0, sourceText: "hello", sourceKind: .ocr)
        #expect(entry.sourceKind == .ocr)
        #expect(Store.makeHistoryStub().isEmpty)
    }

    @Test("默认库路径落在 Application Support/TranslationReader 下")
    func defaultDatabaseURL() {
        let url = Store.defaultDatabaseURL()
        #expect(url.lastPathComponent == "store.sqlite3")
        #expect(url.path.contains("TranslationReader"))
    }

    @Test("设置 Codable 往返（UserDefaults 独立 suite）")
    func settingsRoundTrip() throws {
        let suiteName = "storetest.settings." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings.test")
        var settings = AppSettings.default
        settings.general.autoSpeak = false
        settings.translate.baseURL = "https://api.example.com/v1"
        settings.translate.modelAdvanced = "gpt-4o"
        settings.hotkeys.capture = "opt+shift+s"
        settings.history.limit = 500
        store.save(settings)

        let loaded = store.load()
        #expect(loaded == settings)
        #expect(loaded.translate.baseURL == "https://api.example.com/v1")
        #expect(loaded.history.limit == 500)
    }

    @Test("旧版设置数据仍能加载（升级不重置热键等）")
    func legacySettingsUpgrade() throws {
        let suiteName = "storetest.settings.legacy." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = AppSettings.default
        settings.hotkeys.capture = "opt+shift+s"
        settings.translate.baseURL = "https://api.example.com/v1"
        let data = try JSONEncoder().encode(settings)
        let object = try JSONSerialization.jsonObject(with: data)
        var root = try #require(object as? [String: Any])
        var translate = try #require(root["translate"] as? [String: Any])
        translate.removeValue(forKey: "engine")
        translate.removeValue(forKey: "machineService")
        translate.removeValue(forKey: "machineTimeoutMs")
        root["translate"] = translate
        defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: "settings.test")

        let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings.test")
        let loaded = store.load()
        #expect(loaded.translate.engine == .machine)
        #expect(loaded.translate.baseURL == "https://api.example.com/v1")
        #expect(loaded.hotkeys.capture == "opt+shift+s")
    }

    @Test("损坏或缺失的设置回落到默认值，不崩")
    func settingsFallback() throws {
        let suiteName = "storetest.settings.bad." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings.test")
        #expect(store.load() == AppSettings.default)

        defaults.set(Data("not-json".utf8), forKey: "settings.test")
        #expect(store.load() == AppSettings.default)
    }

    @Test("Keychain 读写删 apiKey（真实 kSecClassGenericPassword）")
    func keychainRoundTrip() throws {
        let service = "com.local.translationreader.test." + UUID().uuidString
        let store = KeychainStore(service: service)
        defer { try? store.removeSecret(for: KeychainStore.apiKeyAccount) }

        #expect(try store.secret(for: KeychainStore.apiKeyAccount) == nil)
        try store.setSecret("sk-unit-test-value", for: KeychainStore.apiKeyAccount)
        #expect(try store.secret(for: KeychainStore.apiKeyAccount) == "sk-unit-test-value")

        try store.setSecret("sk-unit-test-rotated", for: KeychainStore.apiKeyAccount)
        #expect(try store.secret(for: KeychainStore.apiKeyAccount) == "sk-unit-test-rotated")

        try store.removeSecret(for: KeychainStore.apiKeyAccount)
        #expect(try store.secret(for: KeychainStore.apiKeyAccount) == nil)
        // 重复删除不应抛错
        try store.removeSecret(for: KeychainStore.apiKeyAccount)
    }

    @Test("apiKey 便捷入口与通用入口一致")
    func apiKeyConvenience() throws {
        let service = "com.local.translationreader.test." + UUID().uuidString
        let store = KeychainStore(service: service)
        defer { try? store.removeAPIKey() }

        try store.setAPIKey("sk-convenience")
        #expect(try store.apiKey() == "sk-convenience")
        try store.removeAPIKey()
        #expect(try store.apiKey() == nil)
    }

    @Test("Keychain 错误信息里不含明文")
    func keychainErrorHasNoSecret() {
        let error = KeychainError.unexpectedStatus(-34018)
        #expect(!error.description.contains("sk-"))
        #expect(error.description.contains("-34018"))
    }
}
