import Foundation

/// 需要用户授权的 TCC 能力（文档 §7）。
public enum PermissionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case accessibility
    case screenRecording

    public var displayName: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        }
    }

    /// 文档 §7 的深链。
    public var settingsDeepLink: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }
}

/// 跨模块统一错误。所有 UI 文案在此集中，模块间不各写一份。
public enum AppError: Error, Equatable, Sendable {
    case unauthorized(host: String?)
    case network(underlying: String)
    case timeout(seconds: Double?)
    case invalidResponse(reason: String)
    case ttsFailed(reason: String)
    case permissionDenied(kind: PermissionKind)
    case missingAPIKey
    case cancelled
    case unknown(message: String)

    /// 面向用户的中文文案；永不回显 apiKey（文档 §6.7 末段）。
    public var userMessage: String {
        switch self {
        case .unauthorized(let host):
            let suffix = host.map { "（\($0)）" } ?? ""
            return "鉴权失败\(suffix)：请检查 API Key 与端点。"
        case .network(let underlying):
            return "网络错误：\(underlying)"
        case .timeout(let seconds):
            let suffix = seconds.map { "（\(Int($0))s）" } ?? ""
            return "请求超时\(suffix)，请重试。"
        case .invalidResponse(let reason):
            return "响应格式不合法：\(reason)"
        case .ttsFailed(let reason):
            return "朗读失败：\(reason)"
        case .permissionDenied(let kind):
            return "缺少「\(kind.displayName)」权限，请到系统设置中授权。"
        case .missingAPIKey:
            return "尚未配置模型 API Key。"
        case .cancelled:
            return "已取消。"
        case .unknown(let message):
            return message.isEmpty ? "未知错误。" : message
        }
    }

    /// 文档 §4.3「未授权」分支：是否该弹系统授权引导卡。
    public var requiresPermissionGuide: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}
