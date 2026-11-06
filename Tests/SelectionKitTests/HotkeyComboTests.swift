import Testing
import Carbon
import Contracts
import HotkeyKit

/// 热键 combo 字符串 ↔ 键码/修饰位互转（文档 §7 的默认键位格式如 "opt+space"）。
@Suite("HotkeyKit：combo 互转与冲突检测")
struct HotkeyComboTests {
    @Test("opt+space 解析出 Carbon 键码与修饰位")
    func parseOptSpace() throws {
        let combo = try #require(HotkeyCombo(string: "opt+space"))
        #expect(combo.keyCode == 49)
        #expect(combo.modifiers == .option)
        #expect(combo.modifiers.carbonMask == UInt32(optionKey))
        #expect(combo.string == "opt+space")
        #expect(combo.displayString == "⌥Space")
        #expect(combo.isRegistrable)
    }

    @Test("字符串 → 结构 → 字符串 往返稳定（含别名与符号写法）")
    func roundTrip() throws {
        let cases: [(String, String)] = [
            ("opt+space", "opt+space"),
            ("cmd+shift+a", "shift+cmd+a"),
            ("␣cmd+q", ""),  // 占位，下面单独断言非法输入
            ("⌥Space", "opt+space"),
            ("⌘⇧A", "shift+cmd+a"),
            ("ctrl+alt+delete", "ctrl+opt+delete"),
            ("opt+s", "opt+s"),
            ("opt+.", "opt+period"),
            ("opt+f5", "opt+f5"),
            ("f5", "f5"),
        ]
        for (raw, expected) in cases where !expected.isEmpty {
            let combo = try #require(HotkeyCombo(string: raw), "无法解析 \(raw)")
            #expect(combo.string == expected, "输入 \(raw)")
            // 再用规范化字符串重新解析，必须得到同一个 combo
            #expect(HotkeyCombo(string: combo.string) == combo)
        }
    }

    @Test("非法输入返回 nil")
    func rejectsInvalid() {
        #expect(HotkeyCombo(string: "") == nil)
        #expect(HotkeyCombo(string: "opt+") == nil)
        #expect(HotkeyCombo(string: "opt+nonsense") == nil)
        #expect(HotkeyCombo(string: "bogus+space") == nil)
    }

    @Test("裸键不可注册，功能键可以")
    func registrability() throws {
        #expect(HotkeyCombo(string: "space")?.isRegistrable == false)
        #expect(HotkeyCombo(string: "a")?.isRegistrable == false)
        #expect(HotkeyCombo(string: "f5")?.isRegistrable == true)
        #expect(HotkeyCombo(string: "opt+a")?.isRegistrable == true)
    }

    @Test("AppSettings 默认键位都能解析")
    func defaultsParse() {
        let combos = HotkeyKit.defaultCombos
        #expect(combos.count == 3)
        #expect(combos.map { $0.string } == ["opt+space", "opt+s", "opt+r"])
        #expect(HotkeyKit.BindingPlaceholder.defaults.count == 3)
    }

    @Test("NSEvent 键码 → combo（录制路径）")
    func fromKeyCode() throws {
        let combo = try #require(HotkeyCombo(keyCode: 49, modifiers: [.command]))
        #expect(combo.string == "cmd+space")
        #expect(HotkeyCombo(keyCode: 200, modifiers: [.command]) == nil) // 未知键码
    }

    @Test("同一 combo 重复注册返回冲突；注销后可重注册；unregisterAll 后清空")
    func conflictDetection() throws {
        let registry = HotkeyRegistry()
        defer { registry.shutdown() }

        let combo = try #require(HotkeyCombo(string: "ctrl+opt+shift+f19"))
        switch registry.register(combo, handler: { _ in }) {
        case .success:
            break
        case .failure(let error):
            Issue.record("首次注册被拒：\(error)")
            return
        }
        #expect(registry.isRegistered(combo))
        #expect(registry.registeredCombos == [combo])

        switch registry.register(combo, handler: { _ in }) {
        case .success:
            Issue.record("重复注册本应冲突，却成功了")
        case .failure(let error):
            #expect(error == .duplicateCombo(combo.string))
        }

        registry.unregister(combo)
        #expect(registry.isRegistered(combo) == false)
        #expect(registry.registeredCombos.isEmpty)
        #expect(registry.register(combo, handler: { _ in }).isSuccess)

        registry.unregisterAll()
        #expect(registry.registeredCombos.isEmpty)
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
