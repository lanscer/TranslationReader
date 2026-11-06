import Foundation
import Contracts

/// 文档 §5.2 / §7：全局热键模块。对外只暴露组合键模型、Carbon 注册器与录制器，
/// 键位字符串来自 Contracts.AppSettings.Hotkeys（如 "opt+space"）。
public enum HotkeyKit {
    public static let moduleName = "HotkeyKit"

    /// 声明本模块消费的共享契约（可见性自检用）。
    public static let declaredContracts = ["Contracts"]

    /// 文档 §7 的三个默认动作键，顺序固定：翻译 / 截图 / 复读。
    public static var defaultCombos: [HotkeyCombo] {
        [
            HotkeyCombo(string: AppSettings.default.hotkeys.translate),
            HotkeyCombo(string: AppSettings.default.hotkeys.capture),
            HotkeyCombo(string: AppSettings.default.hotkeys.repeatLast),
        ].compactMap { $0 }
    }

    public static func makeRegistry() -> HotkeyRegistry {
        HotkeyRegistry()
    }

    @MainActor
    public static func makeRecorder() -> HotkeyRecorder {
        HotkeyRecorder()
    }

    public struct BindingPlaceholder: Hashable, Sendable {
        public let combo: String
        public init(combo: String) { self.combo = combo }

        public static let defaults = [
            BindingPlaceholder(combo: AppSettings.default.hotkeys.translate),
            BindingPlaceholder(combo: AppSettings.default.hotkeys.capture),
            BindingPlaceholder(combo: AppSettings.default.hotkeys.repeatLast),
        ]
    }
}
