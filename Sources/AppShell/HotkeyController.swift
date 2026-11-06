import AppKit
import Contracts
import HotkeyKit

/// 全局热键注册与重绑（文档 §7）。三个动作固定：翻译 / 截图 / 复读。
@MainActor
final class HotkeyController {
    private unowned let env: AppEnvironment
    private let registry = HotkeyRegistry()
    private(set) var failures: [HotkeyAction: String] = [:]
    private(set) var registered: [HotkeyAction: HotkeyCombo] = [:]

    init(env: AppEnvironment) {
        self.env = env
    }

    /// 全量注册（启动时和「恢复默认」后调用）。重复注册同一动作会先注销旧键。
    func registerAll() {
        failures = [:]
        for action in HotkeyAction.allCases {
            switch rebind(action) {
            case .success:
                break
            case .failure(let error):
                failures[action] = error.errorDescription ?? String(describing: error)
            }
        }
        let summary = HotkeyAction.allCases.map { action in
            let combo = env.settings.combo(for: action)
            let status = failures[action] == nil ? "ok" : "fail"
            return "\(action.rawValue)=\(combo)(\(status))"
        }.joined(separator: " ")
        AppLog.echo("热键注册：" + summary, AppLog.ui)
    }

    @discardableResult
    func rebind(_ action: HotkeyAction) -> Result<HotkeyCombo, HotkeyRegistrationError> {
        if let existing = registered[action] {
            registry.unregister(existing)
            registered[action] = nil
        }
        let comboString = env.settings.combo(for: action)
        let result = registry.register(comboString) { combo in
            AppLog.echo("热键触发 " + combo.string, AppLog.ui)
            Task { @MainActor in
                AppRouter.shared.perform(AppRouter.action(forHotkey: action))
            }
        }
        switch result {
        case .success(let combo):
            registered[action] = combo
            failures[action] = nil
        case .failure(let error):
            failures[action] = error.errorDescription ?? String(describing: error)
        }
        return result
    }

    func unregisterAll() {
        registry.shutdown()
        registered.removeAll()
    }
}
