import Testing
import Foundation
import CoreGraphics
import AppKit
import Contracts
@testable import SelectionKit

@Suite("选区闸门（文档 §3.1 不应出现的场景）")
struct SelectionGateTests {
    let gate = SelectionGate(ownBundleID: "com.local.translationreader")

    @Test("正常选中文段放行")
    func admitsRealSelection() {
        #expect(gate.evaluate(text: "hello world", bundleID: "com.google.Chrome") == nil)
        #expect(gate.evaluate(text: "翻译成中文", bundleID: "com.apple.TextEdit") == nil)
    }

    @Test("空/纯空白拦截")
    func rejectsEmpty() {
        #expect(gate.evaluate(text: "", bundleID: "com.google.Chrome") == .empty)
        #expect(gate.evaluate(text: "   ", bundleID: "com.google.Chrome") == .empty)
    }

    @Test("单字符拦截（文档 §3.1：单字符不弹浮条）")
    func rejectsSingleCharacter() {
        #expect(gate.evaluate(text: "a", bundleID: "com.apple.TextEdit") == .tooShort)
        #expect(gate.evaluate(text: "鸟", bundleID: "com.apple.TextEdit") == .tooShort)
        #expect(gate.evaluate(text: "鸟 bird", bundleID: "com.apple.TextEdit") == nil)
    }

    @Test("纯数字拦截（含千分位与百分号）")
    func rejectsDigitsOnly() {
        #expect(gate.evaluate(text: "12345", bundleID: "com.apple.TextEdit") == .digitsOnly)
        #expect(gate.evaluate(text: "1,234.50", bundleID: "com.apple.TextEdit") == .digitsOnly)
        #expect(gate.evaluate(text: "42%", bundleID: "com.apple.TextEdit") == .digitsOnly)
        #expect(gate.evaluate(text: "42 件", bundleID: "com.apple.TextEdit") == nil)
    }

    @Test("密码框 / 黑名单 / 自身 App 拦截")
    func rejectsPrivateContexts() {
        #expect(gate.evaluate(text: "secret", bundleID: "com.google.Chrome", isSecure: true) == .secureField)
        #expect(gate.evaluate(text: "rm -rf", bundleID: "com.apple.Terminal") == .blockedApp)
        #expect(gate.evaluate(text: "hello", bundleID: "com.local.translationreader") == .ownApp)
    }

    @Test("取词关闭时一律拦截")
    func disabledGate() {
        var disabled = gate
        disabled.enabled = false
        #expect(disabled.evaluate(text: "hello world", bundleID: "com.google.Chrome") == .disabled)
        #expect(disabled.preflight(bundleID: "com.google.Chrome", isSecure: false) == .disabled)
    }

    @Test("黑名单来自 AppSettings.selection")
    func fromSettings() {
        var settings = AppSettings.default
        settings.selection.blocklist = ["com.apple.Preview"]
        let fromSettings = SelectionGate(settings: settings, ownBundleID: "com.local.translationreader")
        #expect(fromSettings.preflight(bundleID: "com.apple.Preview", isSecure: false) == .blockedApp)
        #expect(fromSettings.preflight(bundleID: "com.google.Chrome", isSecure: false) == nil)
    }
}

@Suite("AX → AppKit 坐标换算（左上都原点 → 左下原点）")
struct AXGeometryTests {
    @Test("主屏 900pt：y 轴翻转为 900 - y - height")
    func flipsVertically() {
        let ax = CGRect(x: 100, y: 50, width: 40, height: 20)
        let appKit = AXGeometry.appKitRect(fromAX: ax, primaryScreenHeight: 900)
        #expect(appKit == CGRect(x: 100, y: 830, width: 40, height: 20))
        #expect(appKit.minX == ax.minX)
        #expect(appKit.width == ax.width)
        #expect(appKit.height == ax.height)
    }

    @Test("往返换算回到原值（对合）")
    func roundTrip() {
        let ax = CGRect(x: 12, y: 34, width: 56, height: 78)
        let appKit = AXGeometry.appKitRect(fromAX: ax, primaryScreenHeight: 1080)
        let back = AXGeometry.axRect(fromAppKit: appKit, primaryScreenHeight: 1080)
        #expect(back == ax)
    }

    @Test("贴顶与贴底的边界")
    func edges() {
        let top = AXGeometry.appKitRect(fromAX: CGRect(x: 0, y: 0, width: 10, height: 10), primaryScreenHeight: 900)
        #expect(top.maxY == 900)
        let bottom = AXGeometry.appKitRect(fromAX: CGRect(x: 0, y: 890, width: 10, height: 10), primaryScreenHeight: 900)
        #expect(bottom.minY == 0)
    }

    @Test("外接屏（负坐标）不受主屏翻转影响 x")
    func negativeOrigins() {
        let ax = CGRect(x: -1200, y: 100, width: 20, height: 20)
        let appKit = AXGeometry.appKitRect(fromAX: ax, primaryScreenHeight: 900)
        #expect(appKit.minX == -1200)
        #expect(appKit.minY == 780)
    }

    @Test("null / infinite 矩形退化为 zero，不炸")
    func degenerate() {
        #expect(AXGeometry.appKitRect(fromAX: .null, primaryScreenHeight: 900) == .zero)
        #expect(AXGeometry.appKitRect(fromAX: .infinite, primaryScreenHeight: 900) == .zero)
    }
}

@Suite("剪贴板兜底：changeCount 判定与快照恢复")
struct ClipboardFallbackTests {
    @Test("期间只有我们自己的 ⌘C → 恢复用户原剪贴板")
    func restoreWhenUserDidNotTouch() {
        #expect(ClipboardArbiter.decide(copiedAtChangeCount: 41, observedChangeCount: 41) == .restore)
    }

    @Test("用户在此期间又改过剪贴板 → 绝不覆盖用户内容")
    func keepUserContentWhenTouched() {
        #expect(ClipboardArbiter.decide(copiedAtChangeCount: 41, observedChangeCount: 42) == .keepUserContent)
        #expect(ClipboardArbiter.decide(copiedAtChangeCount: 41, observedChangeCount: 100) == .keepUserContent)
        #expect(ClipboardArbiter.decide(copiedAtChangeCount: 0, observedChangeCount: 1) == .keepUserContent)
    }

    @Test("真实 NSPasteboard：快照 → 被覆盖 → 恢复回原字符串")
    func snapshotRestoreRoundTrip() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.local.translationreader.tests.roundtrip"))
        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("用户的原始剪贴板", forType: .string)

        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        #expect(snapshot.itemCount == 1)
        let before = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("我们合成 ⌘C 复制到的选区文本", forType: .string)
        #expect(pasteboard.changeCount != before)

        let copiedAt = pasteboard.changeCount
        #expect(ClipboardArbiter.decide(copiedAtChangeCount: copiedAt, observedChangeCount: pasteboard.changeCount) == .restore)

        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "用户的原始剪贴板")
        #expect(pasteboard.changeCount > copiedAt)
    }

    @Test("空剪贴板快照恢复后仍是空")
    func emptySnapshot() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.local.translationreader.tests.empty"))
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        #expect(snapshot.isEmpty)
        pasteboard.setString("临时内容", forType: .string)
        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
    }
}

@Suite("SelectionKit 契约")
struct SelectionKitContractTests {
    @Test("makeReader 返回真实实现（AX + 兜底）")
    func makeReaderIsReal() async {
        let reader = SelectionKit.makeReader()
        #expect(reader != nil)
        // 无辅助功能授权或前台无选区时返回 nil，但不崩、不阻塞。
        _ = await reader?.currentSelection()
    }

    @Test("Selection 契约跨模块可见")
    func contractVisible() {
        let selection = Selection(text: "hi", bounds: .zero, appBundleID: "com.local.test")
        #expect(selection.text == "hi")
        #expect(selection.isSecure == false)
        #expect(LanguagePair.default.target == .zhHans)
    }
}
