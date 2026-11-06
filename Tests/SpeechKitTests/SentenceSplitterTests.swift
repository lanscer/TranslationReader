import SpeechKit
import Testing

@Suite("分句")
struct SentenceSplitterTests {
    @Test("中文按句末标点切分")
    func chinese() {
        let text = "今天天气不错。我们出去走走吧！好吗？"
        #expect(SentenceSplitter.split(text) == ["今天天气不错。", "我们出去走走吧！", "好吗？"])
    }

    @Test("英文按句末标点切分，小数点与缩写不断句")
    func english() {
        let text = "The value is 3.14 today. Mr. Smith went home. Really?"
        let sentences = SentenceSplitter.split(text)
        #expect(sentences.count == 3)
        #expect(sentences[0] == "The value is 3.14 today.")
        #expect(sentences[1] == "Mr. Smith went home.")
        #expect(sentences[2] == "Really?")
    }

    @Test("日文与中文混排都能切")
    func japanese() {
        let text = "これはテストです。次の文です！中文也要切。"
        #expect(SentenceSplitter.split(text).count == 3)
    }

    @Test("闭合引号跟随前句")
    func closers() {
        #expect(SentenceSplitter.split("他说“走吧。”然后离开。") == ["他说“走吧。”", "然后离开。"])
        #expect(SentenceSplitter.split("「行きましょう。」と言った。").count == 2)
    }

    @Test("换行是硬断句，空白句被丢弃")
    func newlines() {
        let text = "第一行\n\n第二行。   \n第三行"
        #expect(SentenceSplitter.split(text) == ["第一行", "第二行。", "第三行"])
    }

    @Test("超长句按软断点切开且不超上限太多")
    func maxLength() {
        let text = String(repeating: "这是一句很长的话，", count: 40) + "结束。"
        let sentences = SentenceSplitter.split(text, maxLength: 60)
        #expect(sentences.count > 1)
        #expect(sentences.allSatisfy { $0.count <= 62 })
        #expect(sentences.joined().replacingOccurrences(of: " ", with: "").hasSuffix("结束。"))
    }

    @Test("空输入与纯空白返回空数组")
    func empty() {
        #expect(SentenceSplitter.split("").isEmpty)
        #expect(SentenceSplitter.split("   \n  ").isEmpty)
    }
}
