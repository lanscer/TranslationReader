import Contracts
import Foundation

/// 朗读设置的持久化读写接口（文档 §6.7 的 speech 段）。
/// 设置面板（AppShell）只依赖这个协议，语音实现不关心存储细节。
public protocol SpeechSettingsStore: AnyObject {
    var speech: AppSettings.Speech { get }
    func update(_ mutation: (inout AppSettings.Speech) -> Void)
}

public extension SpeechSettingsStore {
    var engineKind: SpeechEngineKind { speech.engine }

    /// 引擎选择写入（§6.6.1「UI 为三段式选择器，切换即生效」）。
    func setEngineKind(_ kind: SpeechEngineKind) {
        update { $0.engine = kind }
    }

    func voiceIdentifier(for lang: String) -> String? {
        let table = speech.voiceByLang
        return table[lang] ?? table[SpeechLanguage.bcp47(lang)] ?? table.matchingKey(for: lang).flatMap { table[$0] }
    }

    func setVoiceIdentifier(_ identifier: String?, for lang: String) {
        update { speech in
            let key = speech.voiceByLang.matchingKey(for: lang) ?? lang
            if let identifier, !identifier.isEmpty {
                speech.voiceByLang[key] = identifier
            } else {
                speech.voiceByLang.removeValue(forKey: key)
            }
        }
    }
}

extension Dictionary where Key == String, Value == String {
    /// 已有表里按语种粗匹配（zh-Hans 与 zh-CN 视为同一档）。
    func matchingKey(for lang: String) -> String? {
        keys.first { SpeechLanguage.matches(voiceLanguage: $0, lang: lang) }
    }
}

/// 生产实现：UserDefaults 存整段 speech 配置（非敏感项，文档 §6.7）。
public final class UserDefaultsSpeechSettingsStore: SpeechSettingsStore {
    public static let defaultsKey = "settings.speech"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cache: AppSettings.Speech

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.Speech.self, from: data) {
            self.cache = decoded
        } else {
            self.cache = .init()
        }
    }

    public var speech: AppSettings.Speech {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    public func update(_ mutation: (inout AppSettings.Speech) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutation(&cache)
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// 测试/预览用内存实现。
public final class InMemorySpeechSettingsStore: SpeechSettingsStore {
    private let lock = NSLock()
    private var value: AppSettings.Speech

    public init(_ value: AppSettings.Speech = .init()) {
        self.value = value
    }

    public var speech: AppSettings.Speech {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func update(_ mutation: (inout AppSettings.Speech) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutation(&value)
    }
}
