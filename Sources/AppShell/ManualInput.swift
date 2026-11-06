import AppKit
import SwiftUI
import Contracts
import DesignSystem

/// 手动输入窗：不依赖任何 TCC 权限的验证 / 使用路径（验收取证也走它）。
@MainActor
final class ManualInputWindowController: NSWindowController {
    private let model: ManualInputModel

    init(env: AppEnvironment) {
        self.model = ManualInputModel(env: env)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "手动输入翻译"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ManualInputView(model: model))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ManualInputModel: ObservableObject {
    @Published var text: String = ""
    private unowned let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    func translate() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let anchor = CGRect(origin: NSEvent.mouseLocation, size: .zero)
        env.card.present(text: trimmed, kind: .hotkey, anchor: anchor)
    }
}

struct ManualInputView: View {
    @ObservedObject var model: ManualInputModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("粘贴或输入要翻译的原文（这条路径不需要辅助功能/屏幕录制权限）")
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textSecondary)
            TextEditor(text: $model.text)
                .font(.system(size: 13))
                .frame(minHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DSColor.divider, lineWidth: 1))
            HStack {
                Spacer(minLength: 0)
                Button("翻译并朗读") { model.translate() }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 240)
    }
}
