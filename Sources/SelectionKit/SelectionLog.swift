import Foundation
import os

/// 取词链路日志出口：默认走 os.Logger；手动验证脚本可注入闭包直接打印。
public typealias SelectionLogSink = @Sendable (String) -> Void

public enum SelectionLog {
    private static let logger = Logger(subsystem: "com.local.translationreader", category: "selection")

    public static let osLogger: SelectionLogSink = { message in
        logger.debug("\(message, privacy: .public)")
    }

    /// 默认出口：os.Logger + 可选 stderr（环境变量 TRANSLATIONREADER_SELECTION_LOG=1 时开启，
    /// 便于 CLI 验证脚本抓取 AX / 兜底两条路径的真实日志）。
    public static let defaultSink: SelectionLogSink = { message in
        osLogger(message)
        if ProcessInfo.processInfo.environment["TRANSLATIONREADER_SELECTION_LOG"] == "1" {
            FileHandle.standardError.write(Data(("[selection] " + message + "\n").utf8))
        }
    }
}
