import AppKit
import ApplicationServices
import Carbon
import Contracts

/// 文档 §6.1 兜底路径：保存剪贴板全量项 → 合成 ⌘C → 轮询 changeCount（≤150ms）→ 读串 →
/// changeCount 比对判定用户是否改动过（改过则不恢复）。需要辅助功能授权（CGEvent 合成按键）。
public final class ClipboardSelectionReader {
    public let gate: SelectionGate
    public let log: SelectionLogSink
    /// 轮询总超时，文档定的是 150ms。
    public let timeout: TimeInterval
    public let pollInterval: TimeInterval

    public init(
        gate: SelectionGate = SelectionGate(),
        log: @escaping SelectionLogSink = SelectionLog.defaultSink,
        timeout: TimeInterval = 0.150,
        pollInterval: TimeInterval = 0.010
    ) {
        self.gate = gate
        self.log = log
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func currentSelection() async -> Selection? {
        guard gate.enabled else {
            log("clipboard: 跳过（取词已禁用）")
            return nil
        }
        guard AXIsProcessTrusted() else {
            log("clipboard: 未获辅助功能授权，无法合成 ⌘C")
            return nil
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let before = pasteboard.changeCount
        log("clipboard: 已保存原剪贴板 \(snapshot.itemCount) 项，changeCount=\(before)")

        guard Self.postCommandC() else {
            log("clipboard: CGEvent 合成 ⌘C 失败")
            return nil
        }
        guard let copiedCount = await waitForChangeCount(pasteboard: pasteboard, since: before) else {
            log("clipboard: \(Int(timeout * 1000))ms 内 changeCount 未变化（复制未发生或目标 App 未响应）")
            return nil
        }

        let text = pasteboard.string(forType: .string) ?? ""
        let decision = ClipboardArbiter.decide(
            copiedAtChangeCount: copiedCount,
            observedChangeCount: pasteboard.changeCount
        )
        switch decision {
        case .restore:
            snapshot.restore(to: pasteboard)
            log("clipboard: 已恢复原剪贴板（changeCount \(before) → \(copiedCount) → \(pasteboard.changeCount)）")
        case .keepUserContent:
            log("clipboard: 期间用户改动过剪贴板（changeCount \(copiedCount) → \(pasteboard.changeCount)），保留用户内容，不恢复")
        }

        if let reason = gate.validate(text: text) {
            log("clipboard: 文本闸门拦截 \(reason.rawValue) len=\(text.count)")
            return nil
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let reason = gate.preflight(bundleID: frontmost, isSecure: false) {
            log("clipboard: 隐私闸门拦截 \(reason.rawValue) bundle=\(frontmost ?? "nil")")
            return nil
        }

        // 兜底路径拿不到选区包围盒，用鼠标位置做锚点（文档 §3.1 的浮条定位下移到 OverlayKit 处理）。
        let anchor = NSEvent.mouseLocation
        log("clipboard: 命中 bundle=\(frontmost ?? "nil") len=\(text.count) anchor=\(AXSelectionReader.describe(CGRect(origin: anchor, size: .zero)))")
        return Selection(
            text: text,
            bounds: CGRect(origin: anchor, size: .zero),
            appBundleID: frontmost ?? "",
            isSecure: false
        )
    }

    private func waitForChangeCount(pasteboard: NSPasteboard, since before: Int) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                return pasteboard.changeCount
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        let current = pasteboard.changeCount
        return current != before ? current : nil
    }

    /// 合成 ⌘C（CGEvent，需要辅助功能授权）。
    static func postCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let key = UInt16(kVK_ANSI_C)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
