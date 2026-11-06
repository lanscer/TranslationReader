import Testing
import AppKit
import CoreGraphics
import Contracts
import OverlayKit

/// 文档 §3.1：选区右上角 +8pt、贴边自动翻转；§6.2：多屏取包含选区的屏。
@Suite("OverlayKit：浮条定位与多屏选择")
struct OverlayLayoutTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let barSize = CGSize(width: 156, height: 32)

    @Test("常规情况：选区右上角 +8pt")
    func rightTopWithOffset() {
        let selection = CGRect(x: 300, y: 400, width: 200, height: 20)
        let placement = OverlayLayout.barPlacement(selection: selection, size: barSize, screenVisibleFrame: screen, offset: 8)
        #expect(placement.frame.origin.x == 508)
        #expect(placement.frame.origin.y == 428)
        #expect(placement.frame.size == barSize)
        #expect(placement.flippedHorizontally == false)
        #expect(placement.flippedVertically == false)
        // 不遮挡选区本身
        #expect(placement.frame.intersects(selection) == false)
    }

    @Test("贴右边缘：水平翻转到选区左侧")
    func flipsHorizontallyAtRightEdge() {
        let selection = CGRect(x: 1350, y: 400, width: 80, height: 20)
        let placement = OverlayLayout.barPlacement(selection: selection, size: barSize, screenVisibleFrame: screen, offset: 8)
        #expect(placement.flippedHorizontally)
        #expect(placement.frame.maxX == selection.minX - 8)
        #expect(placement.frame.maxX <= screen.maxX)
    }

    @Test("贴顶边缘：垂直翻转到选区下方")
    func flipsVerticallyAtTopEdge() {
        let selection = CGRect(x: 300, y: 880, width: 120, height: 18)
        let placement = OverlayLayout.barPlacement(selection: selection, size: barSize, screenVisibleFrame: screen, offset: 8)
        #expect(placement.flippedVertically)
        #expect(placement.frame.maxY == selection.minY - 8)
        #expect(placement.frame.minY >= screen.minY)
    }

    @Test("极端贴角：翻转后仍出界则夹紧到屏内，整块可见")
    func clampsInsideScreen() {
        let selection = CGRect(x: 1400, y: 890, width: 40, height: 10)
        let placement = OverlayLayout.barPlacement(selection: selection, size: barSize, screenVisibleFrame: screen, offset: 8)
        #expect(placement.flippedHorizontally)
        #expect(placement.flippedVertically)
        #expect(screen.contains(placement.frame))
    }

    @Test("翻译卡：右侧优先，右侧放不下翻到左侧")
    func cardPlacementFlips() {
        let size = CGSize(width: 420, height: 320)
        let selection = CGRect(x: 200, y: 400, width: 100, height: 20)
        let right = OverlayLayout.cardPlacement(selection: selection, size: size, screenVisibleFrame: screen)
        #expect(right.frame.minX == selection.maxX + 12)

        let edgeSelection = CGRect(x: 1200, y: 400, width: 200, height: 20)
        let left = OverlayLayout.cardPlacement(selection: edgeSelection, size: size, screenVisibleFrame: screen)
        #expect(left.flippedHorizontally)
        #expect(left.frame.maxX == edgeSelection.minX - 12)
    }

    @Test("多屏：取包含选区的那块屏")
    func picksContainingScreen() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let onMain = CGRect(x: 100, y: 100, width: 50, height: 20)
        let onExternal = CGRect(x: 2000, y: 300, width: 50, height: 20)
        #expect(OverlayLayout.screenIndex(containing: onMain, screens: [main, external]) == 0)
        #expect(OverlayLayout.screenIndex(containing: onExternal, screens: [main, external]) == 1)
        #expect(OverlayLayout.screenIndex(containing: onMain, screens: []) == nil)
    }

    @Test("跨屏选区：取相交面积最大的屏")
    func picksLargestIntersection() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let spanning = CGRect(x: 1400, y: 100, width: 400, height: 20)
        #expect(OverlayLayout.screenIndex(containing: spanning, screens: [main, external]) == 1)
    }

    @Test("浮条窗口不能成为 key window（文档 §3.1 硬约束）")
    @MainActor
    func barPanelNeverBecomesKey() {
        let panel = SelectionBarPanel(model: SelectionBarModel())
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.isVisible == false)
    }

    @Test("翻译弹窗可以成为 key window（为了选中文本）")
    @MainActor
    func translationPanelBecomesKey() {
        let panel = TranslationPanel(model: TranslationCardModel())
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain == false)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test("浮条实际 present 的位置与尺寸可取证")
    @MainActor
    func barPanelPresentsAtSelection() {
        let selection = Selection(text: "hello world", bounds: CGRect(x: 300, y: 400, width: 200, height: 20), appBundleID: "com.local.test")
        let panel = SelectionBarPanel(model: SelectionBarModel())
        let placement = panel.present(selection: selection, screen: nil)
        #expect(panel.isVisible)
        #expect(placement.frame.size.width > 1)
        #expect(placement.frame.origin.y >= selection.bounds.maxY)
        print("BAR-PLACEMENT frame=" + String(describing: placement.frame) + " flippedH=" + String(placement.flippedHorizontally) + " flippedV=" + String(placement.flippedVertically))
        panel.dismiss()
    }
    @Test("弹窗 Esc / ⌘W 命中关闭快捷键")
    @MainActor
    func closesOnEscapeAndCommandW() throws {
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        #expect(TranslationPanel.isEscape(escape))
        #expect(TranslationPanel.isCloseShortcut(escape) == false)

        let commandW = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        ))
        #expect(TranslationPanel.isCloseShortcut(commandW))
        #expect(TranslationPanel.isEscape(commandW) == false)
    }
}
