import SwiftUI

/// 左键菜单（文档 §3.6）：翻译剪贴板 / 手动输入 / 截图 OCR / 复读上一条 / 历史 / 设置 / 权限自检 / 退出。
struct MenuBarMenu: View {
    var body: some View {
        Button(AppAction.translateClipboard.title) { AppRouter.shared.perform(.translateClipboard) }
        Button(AppAction.manualInput.title) { AppRouter.shared.perform(.manualInput) }
        Button(AppAction.captureOCR.title) { AppRouter.shared.perform(.captureOCR) }
        Button(AppAction.repeatLast.title) { AppRouter.shared.perform(.repeatLast) }
        Divider()
        Button(AppAction.history.title) { AppRouter.shared.perform(.history) }
        Button(AppAction.settings.title) { AppRouter.shared.perform(.settings) }
        Button(AppAction.permissionCheck.title) { AppRouter.shared.perform(.permissionCheck) }
        Divider()
        Button(AppAction.quit.title) { AppRouter.shared.perform(.quit) }
    }
}
