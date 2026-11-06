import AppKit
import Carbon

/// 快捷键录制：只装**本地**监听（设置窗是自己的 key window），
/// 因此不需要「输入监控」或辅助功能权限，权限成本为 0。
@MainActor
public final class HotkeyRecorder {
    public enum Outcome: Equatable, Sendable {
        case captured(HotkeyCombo)
        case cancelled
    }

    public var onFinish: ((Outcome) -> Void)?
    public private(set) var isRecording = false
    private var monitor: Any?

    public init() {}

    /// 开始录制；返回是否成功装上监听。
    @discardableResult
    public func start() -> Bool {
        guard !isRecording else { return true }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
        isRecording = monitor != nil
        return isRecording
    }

    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    /// 返回 true 表示事件已被录制器吞掉（不再传给 AppKit，避免响铃与触发原有快捷键）。
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            return false
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == UInt16(kVK_Escape), HotkeyModifiers(nsFlags: flags).isEmpty {
                finish(.cancelled)
                return true
            }
            let modifiers = HotkeyModifiers(nsFlags: flags)
            guard let combo = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers),
                  combo.isRegistrable else {
                // 无效键（裸字母、未知键码）：吞掉本次按键但继续录制。
                return true
            }
            finish(.captured(combo))
            return true
        default:
            return false
        }
    }

    private func finish(_ outcome: Outcome) {
        stop()
        onFinish?(outcome)
    }
}
