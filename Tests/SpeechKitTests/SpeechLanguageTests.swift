import Contracts
import SpeechKit
import Testing

@Suite("语种 → BCP-47 映射")
struct SpeechLanguageTests {
    @Test("LangCode 映射")
    func fromLangCode() {
        #expect(SpeechLanguage.bcp47(.zhHans) == "zh-CN")
        #expect(SpeechLanguage.bcp47(.zhHant) == "zh-TW")
        #expect(SpeechLanguage.bcp47(.en) == "en-US")
        #expect(SpeechLanguage.bcp47(.ja) == "ja-JP")
        #expect(SpeechLanguage.bcp47(.ko) == "ko-KR")
        #expect(SpeechLanguage.bcp47(.fr) == "fr-FR")
        #expect(SpeechLanguage.bcp47(.de) == "de-DE")
        #expect(SpeechLanguage.bcp47(.ru) == "ru-RU")
        #expect(SpeechLanguage.bcp47(.pt) == "pt-BR")
        #expect(SpeechLanguage.bcp47(.es) == "es-ES")
    }

    @Test("字符串标签归一化")
    func normalize() {
        #expect(SpeechLanguage.bcp47("zh_CN") == "zh-CN")
        #expect(SpeechLanguage.bcp47("en") == "en-US")
        #expect(SpeechLanguage.bcp47("en-GB") == "en-GB")
        #expect(SpeechLanguage.bcp47("") == "zh-CN")
    }

    @Test("音色语种匹配按主标签放宽")
    func matching() {
        #expect(SpeechLanguage.matches(voiceLanguage: "zh-CN", lang: "zh-Hans"))
        #expect(SpeechLanguage.matches(voiceLanguage: "zh-TW", lang: "zh-Hans"))
        #expect(SpeechLanguage.matches(voiceLanguage: "en-GB", lang: "en"))
        #expect(SpeechLanguage.matches(voiceLanguage: "ja-JP", lang: "en") == false)
    }

    @Test("中英粗分")
    func coarse() {
        #expect(SpeechLanguage.isChinese("zh-Hant"))
        #expect(SpeechLanguage.isEnglish("en-GB"))
        #expect(SpeechLanguage.isChinese("ja") == false)
    }
}
