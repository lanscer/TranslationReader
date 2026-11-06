import Testing
import Foundation
import Contracts
import OCRVision

@Suite("OCR 行聚合与版面顺序")
struct OCRPostProcessTests {

    @Test("契约文本保序输出换行")
    func joinedText() {
        let lines = [
            OcrLine(text: "第一行", confidence: 0.9, box: .zero),
            OcrLine(text: "second", confidence: 0.8, box: .zero),
        ]
        let result = OcrResult(lines: lines, detectedLanguage: "zh-Hans", elapsedMs: 12)
        #expect(result.joinedText == "第一行\nsecond")
        #expect(result.elapsedMs == 12)
        #expect(OCRVision.recognizeStub().lines.isEmpty)
    }

    @Test("中英混排：折行并段、全角标点原样保留")
    func mixedChineseEnglish() {
        let lines = [
            OcrLine(text: "Transformer 模型通过自注意力",
                    confidence: 0.93, box: CGRect(x: 0.10, y: 0.80, width: 0.70, height: 0.05)),
            OcrLine(text: "捕获长距离依赖，无需循环结构。",
                    confidence: 0.95, box: CGRect(x: 0.10, y: 0.73, width: 0.55, height: 0.05)),
            OcrLine(text: "GPT-4 与 Claude 3 都依赖它。",
                    confidence: 0.91, box: CGRect(x: 0.10, y: 0.60, width: 0.60, height: 0.05)),
        ]
        let layout = OcrPostProcessor.layout(lines)

        #expect(layout.isVertical == false)
        #expect(layout.paragraphs.count == 2)
        #expect(layout.paragraphs[0].text == "Transformer 模型通过自注意力捕获长距离依赖，无需循环结构。")
        #expect(layout.paragraphs[1].text == "GPT-4 与 Claude 3 都依赖它。")
        // 全角标点不转半角（文档 §6.3 / 风险 R5）
        #expect(layout.text.contains("，"))
        #expect(!layout.text.contains(",无"))
        #expect(layout.text.split(separator: "\n").count == 2)
        #expect(layout.readingOrder.count == 3)
        // 阅读顺序：先第一段两行（上→下），再第二段
        #expect(layout.readingOrder.first?.text == "Transformer 模型通过自注意力")
    }

    @Test("多列：先左列整段、再右列整段，不跨列并段")
    func multiColumn() {
        let lines = [
            OcrLine(text: "第一列第一行", confidence: 0.9,
                    box: CGRect(x: 0.08, y: 0.80, width: 0.35, height: 0.05)),
            OcrLine(text: "第一列第二行", confidence: 0.9,
                    box: CGRect(x: 0.08, y: 0.73, width: 0.35, height: 0.05)),
            OcrLine(text: "第二列第一行", confidence: 0.9,
                    box: CGRect(x: 0.62, y: 0.80, width: 0.30, height: 0.05)),
            OcrLine(text: "第二列第二行", confidence: 0.9,
                    box: CGRect(x: 0.62, y: 0.73, width: 0.30, height: 0.05)),
        ]
        let layout = OcrPostProcessor.layout(lines)

        #expect(layout.paragraphs.count == 2)
        #expect(layout.paragraphs[0].text == "第一列第一行第一列第二行")
        #expect(layout.paragraphs[1].text == "第二列第一行第二列第二行")
        #expect(layout.text == "第一列第一行第一列第二行\n第二列第一行第二列第二行")
        #expect(layout.readingOrder.map(\.text) == ["第一列第一行", "第一列第二行", "第二列第一行", "第二列第二行"])
    }

    @Test("竖排：列序右→左，列内上→下")
    func verticalText() {
        let lines = [
            OcrLine(text: "右列文字", confidence: 0.9,
                    box: CGRect(x: 0.86, y: 0.30, width: 0.04, height: 0.30)),
            OcrLine(text: "中列文字", confidence: 0.9,
                    box: CGRect(x: 0.78, y: 0.30, width: 0.04, height: 0.30)),
            OcrLine(text: "左列文字", confidence: 0.9,
                    box: CGRect(x: 0.70, y: 0.30, width: 0.04, height: 0.30)),
        ]
        let layout = OcrPostProcessor.layout(lines)

        #expect(layout.isVertical)
        #expect(layout.paragraphs.count == 3)
        #expect(layout.text == "右列文字\n中列文字\n左列文字")
        #expect(layout.readingOrder.count == 3)
    }

    @Test("横排拉丁折行补一个空格，不粘连单词")
    func latinWrapAddsSpace() {
        let lines = [
            OcrLine(text: "The quick brown fox", confidence: 0.9,
                    box: CGRect(x: 0.10, y: 0.80, width: 0.80, height: 0.05)),
            // Vision 行框紧贴字形，正文行距差约 0.1~0.3 行高（实测 1440p 截图 0.31），这里取 0.1。
            OcrLine(text: "jumps over the lazy dog.", confidence: 0.9,
                    box: CGRect(x: 0.10, y: 0.745, width: 0.60, height: 0.05)),
        ]
        let layout = OcrPostProcessor.layout(lines)
        #expect(layout.paragraphs.count == 1)
        #expect(layout.paragraphs[0].text == "The quick brown fox jumps over the lazy dog.")
    }

    @Test("语种判定：假名→日、谚文→韩、汉字简繁分开")
    func languageDetection() {
        #expect(OcrLanguageDetector.detect(text: "これは日本語のテキストです。").code == "ja")
        #expect(OcrLanguageDetector.detect(text: "안녕하세요 반갑습니다").code == "ko")
        let simplified = OcrLanguageDetector.detect(text: "这个问题很简单，我们来看看。")
        #expect(simplified.code == "zh-Hans")
        let traditional = OcrLanguageDetector.detect(text: "這個問題很簡單，我們來看看。")
        #expect(traditional.code == "zh-Hant")
        #expect(OcrLanguageGuess(code: "zh-Hans", confidence: 0.4).needsManualHint)
        #expect(!OcrLanguageGuess(code: "zh-Hans", confidence: 0.9).needsManualHint)
        #expect(OCRVision.lowLanguageConfidenceThreshold == 0.6)
    }
}
