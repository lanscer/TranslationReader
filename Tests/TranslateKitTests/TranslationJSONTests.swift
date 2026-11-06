import Testing
import Foundation
import Contracts
import TranslateKit

@Suite("Stage2 JSON 容错")
struct TranslationJSONTests {
    let request = makeTranslateRequest("bird")

    @Test("代码块围栏 + 前后说明文字也能抠出 JSON")
    func fencedJSON() {
        let content = """
        好的，结果如下：
        ```json
        {"translation":"鸟","target_lang":"zh-Hans","mode":"word","senses":[{"pos":"n.","defs":[{"def":"鸟；禽"}]}]}
        ```
        以上。
        """
        let detail = TranslationJSON.detail(from: content, fallbackTranslation: nil, request: request)
        #expect(detail?.translation == "鸟")
        #expect(detail?.senses.count == 1)
        #expect(detail?.senses.first?.defs.first?.def == "鸟；禽")
    }

    @Test("缺失数组字段兜底为空，不抛错")
    func missingArrays() {
        let content = "{\"translation\":\"鸟\"}"
        let detail = TranslationJSON.detail(from: content, fallbackTranslation: nil, request: request)
        #expect(detail?.senses.isEmpty == true)
        #expect(detail?.notes.isEmpty == true)
        #expect(detail?.targetLang == .zhHans)
    }

    @Test("非法 JSON 返回 nil（触发上层重试/降级）")
    func invalidJSON() {
        #expect(TranslationJSON.detail(from: "完全不是 JSON", fallbackTranslation: nil, request: request) == nil)
        #expect(TranslationJSON.detail(from: "{\"translation\":", fallbackTranslation: nil, request: request) == nil)
    }

    @Test("空对象视为不合格")
    func emptyObjectRejected() {
        #expect(TranslationJSON.detail(from: "{}", fallbackTranslation: nil, request: request) == nil)
    }

    @Test("translation 为空时用 Stage1 译文兜底")
    func translationFallback() {
        let detail = TranslationJSON.detail(
            from: "{\"translation\":\"\",\"notes\":[\"口语\"]}",
            fallbackTranslation: "鸟（Stage1）",
            request: request
        )
        #expect(detail?.translation == "鸟（Stage1）")
        #expect(detail?.notes == ["口语"])
    }

    @Test("字符串里的花括号不破坏括号配对")
    func bracesInsideStrings() {
        let content = "提示：{\"translation\":\"用 {大括号} 测试\"}"
        let detail = TranslationJSON.detail(from: content, fallbackTranslation: nil, request: request)
        #expect(detail?.translation == "用 {大括号} 测试")
    }

    @Test("例句结构完整往返")
    func examplesRoundTrip() {
        let content = """
        {"translation":"一鸟在手","senses":[{"pos":"n.","defs":[{"def":"鸟","examples":[{"src":"a bird in the hand","tgt":"一鸟在手"}]}]}]}
        """
        let detail = TranslationJSON.detail(from: content, fallbackTranslation: nil, request: makeTranslateRequest("bird", mode: .word))
        let example = detail?.senses.first?.defs.first?.examples.first
        #expect(example?.src == "a bird in the hand")
        #expect(example?.tgt == "一鸟在手")
    }

    @Test("JSON 编码后再解码字段一致")
    func encodeDecode() throws {
        let detail = TranslationDetail(
            targetLang: .zhHans,
            translation: "鸟",
            mode: .word,
            senses: [.init(pos: "n.", defs: [.init(def: "鸟", examples: [.init(src: "a bird", tgt: "一只鸟")])])],
            synonyms: [.init(word: "fowl", note: "家禽")],
            usage: [.init(title: "give sb. the bird", body: "起哄")],
            notes: ["口语"]
        )
        let data = try JSONEncoder().encode(detail)
        let decoded = try JSONDecoder().decode(TranslationDetail.self, from: data)
        #expect(decoded == detail)
    }
}
