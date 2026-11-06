import AppKit
import Contracts
import SelectionKit

/// 菜单栏与热键共用的动作入口（文档 §3.6）。
enum AppAction: String {
    case translateClipboard
    case translateSelectionOrClipboard
    case manualInput
    case captureOCR
    case repeatLast
    case history
    case settings
    case permissionCheck
    case quit

    var title: String {
        switch self {
        case .translateClipboard: return "翻译剪贴板"
        case .translateSelectionOrClipboard: return "翻译选区 / 剪贴板"
        case .manualInput: return "手动输入…"
        case .captureOCR: return "截图 OCR"
        case .repeatLast: return "复读上一条"
        case .history: return "历史"
        case .settings: return "设置…"
        case .permissionCheck: return "权限自检"
        case .quit: return "退出"
        }
    }
}

@MainActor
final class AppRouter {
    static let shared = AppRouter()

    private var env: AppEnvironment { AppEnvironment.shared }
    private var manualInput: ManualInputWindowController?

    private init() {}

    static func action(forHotkey action: HotkeyAction) -> AppAction {
        switch action {
        case .translate: return .translateSelectionOrClipboard
        case .capture: return .captureOCR
        case .repeatLast: return .repeatLast
        }
    }

    func perform(_ action: AppAction) {
        switch action {
        case .translateSelectionOrClipboard:
            translateSelectionOrClipboard()
        case .translateClipboard:
            translateClipboard()
        case .manualInput:
            showManualInput()
        case .captureOCR:
            env.capture.run()
        case .repeatLast:
            repeatLast()
        case .history:
            env.historyWindow.show()
        case .settings:
            env.settingsWindow.show(selecting: .account)
        case .permissionCheck:
            env.permissions.show()
        case .quit:
            AppLog.echo("退出", AppLog.lifecycle)
            env.hotkeys.unregisterAll()
            env.selectionWatcher.stop()
            NSApp.terminate(nil)
        }
    }

    // MARK: - 翻译入口

    /// ⌥Space：AX 选区 →（拿不到时）合成 ⌘C 兜底 → 最后才读现有剪贴板（文档 §7）。
    private func translateSelectionOrClipboard() {
        let gate = SelectionGate(settings: env.settings.settings, ownBundleID: SingleInstanceLock.bundleIdentifier)

        guard PermissionCenter.accessibilityGranted else {
            AppLog.echo("⌥Space：辅助功能未授权，直接走剪贴板路径", AppLog.ui)
            translateClipboard()
            return
        }

        // 主路径：AX 直接读选中文本。
        if let selection = AXSelectionReader(gate: gate).currentSelection(),
           gate.validate(text: selection.text) == nil {
            AppLog.echo("⌥Space 命中 AX 选区 len=\(selection.text.count)", AppLog.ui)
            env.card.present(text: selection.text, kind: .selection, anchor: selection.bounds, bundleID: selection.appBundleID)
            return
        }

        // 兜底：不少 App（Electron / 自绘控件）不支持 kAXSelectedTextAttribute，
        // 这时用合成 ⌘C 读剪贴板，读完再把用户原剪贴板还回去。
        AppLog.echo("⌥Space：AX 没拿到选区，尝试合成 ⌘C 兜底", AppLog.ui)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reader = ClipboardSelectionReader(gate: gate, timeout: 0.35)
            if let selection = await reader.currentSelection(),
               gate.validate(text: selection.text) == nil {
                AppLog.echo("⌥Space 命中 ⌘C 兜底 len=\(selection.text.count)", AppLog.ui)
                self.env.card.present(
                    text: selection.text,
                    kind: .selection,
                    anchor: selection.bounds,
                    bundleID: selection.appBundleID
                )
                return
            }
            AppLog.echo("⌥Space：⌘C 兜底也没拿到选区，改读剪贴板", AppLog.ui)
            self.translateClipboard()
        }
    }

    private func translateClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            env.toast.show("剪贴板里没有文本，用「手动输入…」代替", isError: true)
            showManualInput()
            return
        }
        let anchor = CGRect(origin: NSEvent.mouseLocation, size: .zero)
        env.card.present(text: text, kind: .clipboard, anchor: anchor)
    }

    /// ⌥R：复读上一条原文（不重新翻译）。
    private func repeatLast() {
        if let last = env.speech.lastSpokenText, !last.isEmpty {
            env.speech.speak(last, lang: LanguageHint.bcp47(last))
            return
        }
        if let entry = env.recentEntries(limit: 1).first {
            env.speech.speak(entry.sourceText, lang: LanguageHint.bcp47(entry.sourceText))
            return
        }
        env.toast.show("还没有朗读过的原文，先翻译一条", isError: true)
    }

    private func showManualInput() {
        if manualInput == nil {
            manualInput = ManualInputWindowController(env: env)
        }
        manualInput?.show()
    }
}
