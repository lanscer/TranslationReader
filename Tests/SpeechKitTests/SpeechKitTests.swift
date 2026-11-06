import Contracts
import SpeechKit
import Testing

@Suite("SpeechKit 引擎工厂")
struct SpeechKitFactoryTests {
    @Test("三档枚举齐全，两档有真实实现")
    func engineKinds() {
        #expect(SpeechEngineKind.allCases.count == 3)
        #expect(SpeechEngineKind.openai.requiresUserEndpoint)
        #expect(SpeechEngineKind.system.requiresUserEndpoint == false)
        #expect(SpeechKit.availableEngines().contains(.system))
        #expect(SpeechKit.availableEngines().contains(.sherpa))
        #expect(SpeechKit.makeEngine(kind: .openai) == nil)
    }

    @Test("两个引擎都实现 SpeechEngine 契约")
    func enginesConform() {
        let system = SpeechKit.makeEngine(kind: .system)
        let sherpa = SpeechKit.makeEngine(kind: .sherpa)
        #expect(system?.id == "system")
        #expect(system?.needsNetwork == false)
        #expect(sherpa?.id == "sherpa")
        #expect(sherpa?.needsNetwork == false)
    }

    @Test("音色选项可构造")
    func voiceOption() {
        let voice = VoiceOption(
            id: "com.apple.ttsbundle.Tingting-premium",
            name: "Tingting",
            language: "zh-CN",
            quality: .premium
        )
        #expect(voice.quality == .premium)
        #expect(voice.engine == .system)
    }
}
