import Foundation
import Contracts

// TranslateKit：翻译 Provider 工厂。
//
// 默认引擎 = 机器翻译（MachineTranslateProvider，免密钥）；
// AI 翻译（OpenAITranslateProvider，两阶段）为可选项，必须在设置里显式选择。
public enum TranslateKit {
    public static let moduleName = "TranslateKit"

    /// 固定 apiKey 的便捷入口（AppShell 从 Keychain 取一次传入）。
    public static func makeProvider(settings: AppSettings.Translate, apiKey: String? = nil) -> TranslateProvider? {
        makeProvider(settings: settings, engine: settings.engine, apiKeyProvider: { apiKey })
    }

    /// 闭包形态：每次请求重新取 key，设置面板换 key 后下一次请求即生效。
    public static func makeProvider(
        settings: AppSettings.Translate,
        apiKeyProvider: @escaping @Sendable () -> String?
    ) -> TranslateProvider? {
        makeProvider(settings: settings, engine: settings.engine, apiKeyProvider: apiKeyProvider)
    }

    /// 显式指定引擎（卡片顶栏临时切换机器 / AI 用）。
    public static func makeProvider(
        settings: AppSettings.Translate,
        engine: TranslationEngineKind,
        apiKey: String? = nil
    ) -> TranslateProvider? {
        makeProvider(settings: settings, engine: engine, apiKeyProvider: { apiKey })
    }

    /// 机器翻译永远可用（不需要 baseURL）；AI 翻译 baseURL 解析不出端点时返回 nil。
    public static func makeProvider(
        settings: AppSettings.Translate,
        engine: TranslationEngineKind,
        apiKeyProvider: @escaping @Sendable () -> String?
    ) -> TranslateProvider? {
        switch engine {
        case .machine:
            return MachineTranslateProvider(settings: settings)
        case .ai:
            guard OpenAITranslateProvider.completionsURL(baseURL: settings.baseURL) != nil else { return nil }
            return OpenAITranslateProvider(settings: settings, apiKeyProvider: apiKeyProvider)
        }
    }
}

/// 让 Stage2Coalescer 的共享 Task 携带 Sendable 值。
public struct TranslationDetailBox: Sendable {
    public let value: TranslationDetail
    public init(value: TranslationDetail) { self.value = value }
}
