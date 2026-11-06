import AppKit
import ApplicationServices
import Combine
import Contracts
import CaptureKitX
import DesignSystem
import SwiftUI

/// 权限自检（文档 §7）：辅助功能 + 屏幕录制，逐项状态 + 深链。
@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var accessibilityGranted: Bool = false
    @Published private(set) var screenRecordingGranted: Bool = false
    @Published private(set) var checkedAt: Date = .distantPast
    /// 三行诊断：bundle 路径 / 签名身份 / 权限状态（回答「勾了为什么不生效」）。
    @Published private(set) var bundlePath: String = Bundle.main.bundlePath
    @Published private(set) var signingIdentity: String = "读取中…"
    @Published private(set) var lastRequestNote: String?
    /// 只在用户点「向系统请求授权」时置位，用于提示系统框已弹。
    @Published private(set) var isRequesting: Bool = false

    private unowned let env: AppEnvironment
    private var windowController: NSWindowController?

    nonisolated static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    nonisolated static var screenRecordingGranted: Bool {
        ScreenCaptureService.hasScreenRecordingPermission
    }

    init(env: AppEnvironment) {
        self.env = env
        refresh()
    }

    func refresh() {
        accessibilityGranted = Self.accessibilityGranted
        screenRecordingGranted = Self.screenRecordingGranted
        let snapshot = SigningDiagnostics.describe()
        bundlePath = snapshot.bundlePath
        signingIdentity = snapshot.identity
        checkedAt = Date()
        AppLog.echo("权限自检：辅助功能=\(accessibilityGranted ? "已授权" : "未授权") 屏幕录制=\(screenRecordingGranted ? "已授权" : "未授权") bundle=\(snapshot.bundlePath) 签名=\(snapshot.identity)", AppLog.perm)
    }

    // MARK: - 自发授权（只在按钮点击时调用）

    /// 辅助功能：AXIsProcessTrustedWithOptions(prompt: true)。
    /// **只在用户点按钮时调用**，绝不在启动/轮询路径调用（否则每次启动都弹系统框）。
    func requestAccessibilityAuthorization() {
        isRequesting = true
        lastRequestNote = "已向系统请求「辅助功能」授权，请在弹出的系统框里允许。"
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        AppLog.echo("请求辅助功能授权：prompt 已发出，当前 trusted=\(trusted)", AppLog.perm)
        scheduleRefreshAfterRequest()
    }

    /// 屏幕录制：CGRequestScreenCaptureAccess（会弹系统框并登记当前签名的二进制）。
    func requestScreenRecordingAuthorization() {
        isRequesting = true
        lastRequestNote = "已向系统请求「屏幕录制」授权，请在弹出的系统框里允许。"
        let granted = ScreenCaptureService.requestScreenRecordingPermission()
        AppLog.echo("请求屏幕录制授权：当前 granted=\(granted)", AppLog.perm)
        scheduleRefreshAfterRequest()
    }

    /// 点完按钮 1.5s 自动 refresh（系统可能还没来得及落盘）。
    private func scheduleRefreshAfterRequest() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refresh()
            isRequesting = false
        }
    }

    func openSettings(_ kind: PermissionKind) {
        guard let url = URL(string: kind.settingsDeepLink) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 首次启动 / 菜单「权限自检」都走这个窗。
    func show() {
        refresh()
        if windowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "权限自检"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: PermissionSelfCheckView(center: self))
            windowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }
}

/// 自检页 + 授权引导（文档 §4.3「未授权」分支）。
struct PermissionSelfCheckView: View {
    @ObservedObject var center: PermissionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("逐项检测 TCC 权限。授权后回到本 App 点「重新检测」即生效。")
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                PermissionStatusRow(
                    kind: .accessibility,
                    granted: center.accessibilityGranted,
                    onRequestAuthorization: { center.requestAccessibilityAuthorization() },
                    onOpenSettings: { center.openSettings(.accessibility) }
                )
                PermissionStatusRow(
                    kind: .screenRecording,
                    granted: center.screenRecordingGranted,
                    onRequestAuthorization: { center.requestScreenRecordingAuthorization() },
                    onOpenSettings: { center.openSettings(.screenRecording) }
                )
                if let note = center.lastRequestNote {
                    Text(note + (center.isRequesting ? "（1.5 秒后自动重新检测…）" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.textSecondary)
                }
            }

            // 三行诊断：勾了还是不生效时，先看清二进制身份
            VStack(alignment: .leading, spacing: 3) {
                Text("诊断")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DSColor.textSecondary)
                Text("① bundle：\(center.bundlePath)")
                Text("② 签名：\(center.signingIdentity)")
                Text("③ 状态：辅助功能=\(center.accessibilityGranted ? "已授权" : "未授权") · 屏幕录制=\(center.screenRecordingGranted ? "已授权" : "未授权")")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(DSColor.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DSColor.surfaceSunken)
            )

            if !center.accessibilityGranted {
                Text("若你确认已在系统设置里勾选：可能是系统里存在旧的同名条目，或授权发生在旧版本二进制上。请删除旧条目后用本页「向系统请求授权」重新登记，或把 ~/Applications/TranslationReader.app 直接拖进「辅助功能」列表。")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionGuideCard(
                onOpenAccessibility: { center.requestAccessibilityAuthorization() },
                onOpenScreenRecording: { center.requestScreenRecordingAuthorization() }
            )

            Text("钥匙串询问请点「始终允许」。若反复询问/授权后仍提示未授权，通常是 App 被重新构建过（签名变化导致旧授权与钥匙串 ACL 失效）：① 到「钥匙串访问」删除旧的 com.local.translationreader 条目后重新保存 key；② 重新授权本页两项权限。")
                .font(.system(size: 11))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("ad-hoc 旧条目清理步骤")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DSColor.textSecondary)
                Text("系统设置 → 隐私与安全性 → 辅助功能（以及 屏幕录制）→ 选中旧的 TranslationReader → 点「−」删除 → 点「+」重新添加 ~/Applications/TranslationReader.app")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("未授权时的可用路径：菜单「翻译剪贴板」（⌥Space 读剪贴板）与菜单「手动输入…」不需要辅助功能权限。")
                .font(.system(size: 11))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("重新检测") { center.refresh() }
                Spacer(minLength: 0)
                Text("检测时间 \(center.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 280, alignment: .topLeading)
    }
}
