import Foundation
import Contracts

/// 文档 §5.2 / §6.1：选区读取模块。对外只暴露协议实现与配置，
/// 不依赖 TranslateKit / SpeechKit（依赖方向：SelectionKit → Contracts）。
public enum SelectionKit {
    public static let moduleName = "SelectionKit"

    /// 真实 reader：AX 主路径 + 剪贴板兜底 + 隐私闸门。
    public static func makeReader(
        configuration: SelectionConfiguration = SelectionConfiguration()
    ) -> SelectionReading? {
        SelectionReader(configuration: configuration)
    }

    /// 注入日志出口的版本，手动验证脚本用。
    public static func makeReader(
        configuration: SelectionConfiguration,
        log: @escaping SelectionLogSink
    ) -> SelectionReading? {
        SelectionReader(configuration: configuration, log: log)
    }
}
