import AppKit
import Contracts
import Foundation

/// 取词配置：文档 §3.1 / §6.7（开关、黑名单来自 AppSettings.selection）。
public struct SelectionConfiguration: Sendable {
    public var gate: SelectionGate
    public var clipboardFallbackEnabled: Bool
    public var clipboardTimeout: TimeInterval

    public init(
        gate: SelectionGate = SelectionGate(),
        clipboardFallbackEnabled: Bool = true,
        clipboardTimeout: TimeInterval = 0.150
    ) {
        self.gate = gate
        self.clipboardFallbackEnabled = clipboardFallbackEnabled
        self.clipboardTimeout = clipboardTimeout
    }

    public init(
        settings: AppSettings,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        clipboardFallbackEnabled: Bool = true
    ) {
        self.init(
            gate: SelectionGate(settings: settings, ownBundleID: ownBundleID),
            clipboardFallbackEnabled: clipboardFallbackEnabled,
            clipboardTimeout: 0.150
        )
    }

    public static let defaultConfiguration = SelectionConfiguration()
}

/// SelectionReading 的真实实现：AX 主路径优先，未命中再走剪贴板兜底。
public final class SelectionReader: SelectionReading {
    public let configuration: SelectionConfiguration
    public let log: SelectionLogSink

    private let axReader: AXSelectionReader
    private let clipboardReader: ClipboardSelectionReader
    private let stateLock = NSLock()
    private var lastMilliseconds: Double?

    public init(
        configuration: SelectionConfiguration = SelectionConfiguration(),
        log: @escaping SelectionLogSink = SelectionLog.defaultSink
    ) {
        self.configuration = configuration
        self.log = log
        self.axReader = AXSelectionReader(gate: configuration.gate, log: log)
        self.clipboardReader = ClipboardSelectionReader(
            gate: configuration.gate,
            log: log,
            timeout: configuration.clipboardTimeout
        )
    }

    /// 最近一次 currentSelection() 的耗时（毫秒）。M1「浮条 ≤150ms 出现」的计时口径。
    public var lastReadMilliseconds: Double? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastMilliseconds
    }

    public func currentSelection() async -> Selection? {
        let started = CFAbsoluteTimeGetCurrent()

        if let selection = axReader.currentSelection() {
            record(started)
            log(String(format: "read: AX 路径 \(selection.text.count) 字，耗时 %.2fms", elapsed(since: started)))
            return selection
        }

        guard configuration.clipboardFallbackEnabled else {
            record(started)
            log("read: AX 未命中且兜底已关闭 → nil")
            return nil
        }

        let selection = await clipboardReader.currentSelection()
        record(started)
        let verdict = selection == nil ? "未命中" : "命中"
        log(String(format: "read: 兜底路径 \(verdict)，耗时 %.2fms", elapsed(since: started)))
        return selection
    }

    private func elapsed(since started: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    private func record(_ started: CFAbsoluteTime) {
        stateLock.lock()
        lastMilliseconds = elapsed(since: started)
        stateLock.unlock()
    }
}
