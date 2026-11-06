import Foundation

/// 验收 / 诊断用的 UI 开关。产品 UI 默认不显示任何计时行。
/// 打开方式：设置 → 通用 → 「显示性能指标」，或环境变量 TRANSLATIONREADER_DEBUG_TIMING=1。
enum DebugFlags {
    static let showTimingDefaultsKey = "general.showTiming"

    static var showTiming: Bool {
        if ProcessInfo.processInfo.environment["TRANSLATIONREADER_DEBUG_TIMING"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: showTimingDefaultsKey)
    }

    static func setShowTiming(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: showTimingDefaultsKey)
    }
}
