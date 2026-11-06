import Testing
import Foundation
import CoreGraphics
import Contracts
import DesignSystem
import OverlayKit
import HotkeyKit

/// T6 集成测试：卡片内容推导（DesignSystem）+ 窗口落位（OverlayKit）+ 热键默认值（HotkeyKit）
/// 三方一起验，确保 AppShell 装配用到的规则不会各自漂移。
@Suite("卡片装配与落位集成")
struct CardFlowTests {

    private func detail(mode: TranslateMode, senses: [TranslationDetail.Sense] = [], usage: [TranslationDetail.UsageNote] = []) -> TranslationDetail {
        TranslationDetail(
            sourceLang: .en,
            targetLang: .zhHans,
            translation: "译文",
            mode: mode,
            senses: senses,
            synonyms: [],
            usage: usage,
            notes: []
        )
    }

    @Test("单词 / 句子模式判定")
    func wordLike() {
        #expect(CardDetailLogic.isWordLike("serendipity"))
        #expect(CardDetailLogic.isWordLike("hello"))
        #expect(!CardDetailLogic.isWordLike("hello world"))
        #expect(!CardDetailLogic.isWordLike("A whole sentence with spaces."))
        #expect(CardDetailLogic.isWordLike("翻译"))
        #expect(!CardDetailLogic.isWordLike("这句话没有空格但它明显是一个句子"))
        #expect(!CardDetailLogic.isWordLike("你好，世界"))
        #expect(!CardDetailLogic.isWordLike("   "))
    }

    @Test("两套 tab 固定：单词=简明/例句，句子=用法/出处（不再有重复译文的「译文」tab）")
    func tabs() {
        #expect(CardDetailLogic.tabs(for: .word) == [.concise, .examples])
        #expect(CardDetailLogic.tabs(for: .sentence) == [.usage, .origin])
        #expect(CardDetailLogic.tabs(for: .word).map(\.title) == ["简明", "例句"])
        #expect(CardDetailLogic.tabs(for: .sentence).map(\.title) == ["用法", "出处"])
        #expect(!CardDetailLogic.tabs(for: .sentence).contains(.concise))
    }

    @Test("Stage2 的 mode 优先于文本长度启发式")
    func modeFromDetail() {
        let wordDetail = detail(mode: .word)
        #expect(CardDetailLogic.mode(for: "this is a long sentence with spaces", detail: wordDetail) == .word)
        let sentenceDetail = detail(mode: .sentence)
        #expect(CardDetailLogic.mode(for: "bird", detail: sentenceDetail) == .sentence)
        #expect(CardDetailLogic.mode(for: "bird") == .word)
    }

    @Test("词性分组 + 义项序号悬挂缩进数据")
    func lemmaSections() {
        let senses: [TranslationDetail.Sense] = [
            .init(pos: "n.", defs: [
                .init(def: "鸟；禽", examples: [.init(src: "a bird in the hand", tgt: "一鸟在手")]),
                .init(def: "（俚）人；家伙", examples: []),
            ]),
            .init(pos: "v.", defs: [
                .init(def: "观鸟", examples: []),
            ]),
        ]
        let sections = CardDetailLogic.lemmaSections(from: detail(mode: .word, senses: senses))
        #expect(sections.count == 2)
        #expect(sections[0].pos == "n.")
        #expect(sections[0].defs.map(\.number) == [1, 2])
        #expect(sections[0].defs[0].examples.first?.tgt == "一鸟在手")
        #expect(sections[1].pos == "v.")
        #expect(sections[1].defs.count == 1)
    }

    @Test("Stage2 全空时隐藏细节区（句子模式：只有译文不算细节）")
    func detailVisibility() {
        #expect(!CardDetailLogic.hasDetail(nil))
        #expect(!CardDetailLogic.hasDetail(TranslationDetail(targetLang: .zhHans, translation: "", mode: .sentence)))
        #expect(CardDetailLogic.hasDetail(detail(mode: .sentence, usage: [.init(title: "t", body: "b")]), mode: .sentence))
        #expect(CardDetailLogic.hasDetail(detail(mode: .word, senses: [.init(pos: "n.", defs: [])]), mode: .word))
        // 句子模式下 senses 不产生 tab（那属于单词模式的「简明」）
        #expect(!CardDetailLogic.hasDetail(detail(mode: .sentence, senses: [.init(pos: "n.", defs: [])]), mode: .sentence))
        // 没有细节时整块 tab 区隐藏，正文译文只出现一次
        #expect(!CardDetailLogic.hasDetail(detail(mode: .sentence), mode: .sentence))
    }

    @Test("「出处」tab 取 notes + 近义备注，与「用法」不重叠")
    func originLines() {
        var sample = detail(mode: .sentence, usage: [.init(title: "用法", body: "正文")])
        sample.notes = ["语域偏书面"]
        sample.synonyms = [.init(word: "chance", note: "偶然")]
        let lines = CardDetailLogic.originLines(from: sample)
        #expect(lines.count == 2)
        #expect(lines.first == "语域偏书面")
        #expect(lines.last == "chance：偶然")
        #expect(CardDetailLogic.originLines(from: nil).isEmpty)
        #expect(CardDetailLogic.originLines(from: detail(mode: .sentence)).isEmpty)
    }

    @Test("例句 tab 摊平后保留词性")
    func examplesFlatten() {
        let senses: [TranslationDetail.Sense] = [
            .init(pos: "n.", defs: [
                .init(def: "a", examples: [.init(src: "s1", tgt: "t1")]),
                .init(def: "b", examples: [.init(src: "s2", tgt: "t2")]),
            ]),
            .init(pos: "v.", defs: [.init(def: "c", examples: [.init(src: "s3", tgt: "t3")])]),
        ]
        let flat = CardDetailLogic.examplePairs(from: detail(mode: .word, senses: senses))
        #expect(flat.count == 3)
        #expect(flat.map(\.pos) == ["n.", "n.", "v."])
        #expect(CardDetailLogic.allExamples(from: detail(mode: .word, senses: senses)).map(\.src) == ["s1", "s2", "s3"])
    }

    @Test("浮条落位：贴右边缘自动翻转且不出屏")
    func barPlacementFlips() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 1300, y: 200, width: 120, height: 20)
        let placement = OverlayLayout.barPlacement(
            selection: selection,
            size: CGSize(width: 156, height: 32),
            screenVisibleFrame: screen,
            offset: DSMetric.selectionBarOffset
        )
        #expect(placement.flippedHorizontally)
        #expect(placement.frame.maxX <= screen.maxX)
        #expect(!placement.frame.intersects(selection))
    }

    @Test("卡片落位：右侧放不下翻到左侧，宽度等于 token 宽度")
    func cardPlacementFits() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let selection = CGRect(x: 1000, y: 300, width: 200, height: 20)
        let size = CGSize(width: DSMetric.cardWidth, height: 360)
        let placement = OverlayLayout.cardPlacement(selection: selection, size: size, screenVisibleFrame: screen)
        #expect(placement.frame.width == DSMetric.cardWidth)
        #expect(placement.frame.maxX <= screen.maxX)
        #expect(placement.frame.minX >= screen.minX)
        #expect(placement.flippedHorizontally)
    }

    @Test("多屏：选区落在哪块屏就选哪块")
    func screenIndexPicksContaining() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        ]
        #expect(OverlayLayout.screenIndex(containing: CGRect(x: 100, y: 100, width: 10, height: 10), screens: screens) == 0)
        #expect(OverlayLayout.screenIndex(containing: CGRect(x: 2000, y: 400, width: 10, height: 10), screens: screens) == 1)
        #expect(OverlayLayout.screenIndex(containing: .zero, screens: []) == nil)
    }

    @Test("默认热键可被 HotkeyKit 解析（⌥Space / ⌥S / ⌥R）")
    func defaultHotkeysParse() {
        let settings = AppSettings.default
        let translate = HotkeyCombo(string: settings.hotkeys.translate)
        let capture = HotkeyCombo(string: settings.hotkeys.capture)
        let repeatLast = HotkeyCombo(string: settings.hotkeys.repeatLast)
        #expect(translate != nil)
        #expect(capture != nil)
        #expect(repeatLast != nil)
        #expect(translate?.modifiers.contains(.option) == true)
        #expect(capture?.string == "opt+s")
        #expect(repeatLast?.string == "opt+r")
        #expect(HotkeyKit.defaultCombos.count == 3)
        #expect(translate?.isRegistrable == true)
    }

    @Test("卡片宽度与浮条尺寸都来自 DesignSystem token")
    func metricsComeFromTokens() {
        #expect(OverlayKit.cardSize.width == DSMetric.cardWidth)
        #expect(DSMetric.cardCorner == 12)
        #expect(DSMetric.cardMaxHeight == 560)
        #expect(OverlayKit.PanelKind.selectionBar.rawValue == "selectionBar")
    }
}
