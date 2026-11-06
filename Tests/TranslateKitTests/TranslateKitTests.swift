import Testing
import Contracts
import TranslateKit

@Suite("TranslateKit 入口")
struct TranslateKitEntryTests {
    @Test("模块可被导入")
    func moduleIsWired() {
        #expect(TranslateKit.moduleName == "TranslateKit")
    }

    @Test("请求保留档位与模式")
    func requestKeepsTierAndMode() {
        let request = TranslateRequest(
            text: "hello",
            pair: LanguagePair(source: .en, target: .zhHans),
            tier: .advanced,
            mode: .word
        )
        #expect(request.tier == .advanced)
        #expect(request.mode == .word)
        #expect(request.pair.source == .en)
    }

    @Test("默认引擎 = 机器翻译：不填 baseURL 也产出 Provider")
    func machineAlwaysYieldsProvider() {
        let settings = AppSettings.Translate()
        #expect(settings.engine == .machine)
        let provider = TranslateKit.makeProvider(settings: settings)
        #expect(provider is MachineTranslateProvider)
        #expect(TranslateKit.makeProvider(settings: settings, engine: .machine, apiKey: nil) != nil)
    }

    @Test("AI 引擎 baseURL 为空时不产出 Provider")
    func emptyBaseURLYieldsNilForAI() {
        var settings = AppSettings.Translate()
        settings.engine = .ai
        #expect(TranslateKit.makeProvider(settings: settings) == nil)
        #expect(TranslateKit.makeProvider(settings: settings, engine: .ai, apiKey: "sk-abc") == nil)
    }

    @Test("AI 引擎填了 baseURL 与 key 时产出 Provider")
    func configuredYieldsProvider() {
        var settings = AppSettings.Translate()
        settings.engine = .ai
        settings.baseURL = "https://api.example.com/v1"
        #expect(TranslateKit.makeProvider(settings: settings, apiKey: "sk-abc") != nil)
        #expect(TranslateKit.makeProvider(settings: settings, apiKeyProvider: { "sk-abc" }) != nil)
    }
}
