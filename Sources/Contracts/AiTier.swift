import Foundation

/// 「档位」：标准 / 高级，对应两个模型名（文档 §5.1 附录 C）。
public enum AiTier: String, Codable, CaseIterable, Hashable, Sendable {
    case standard
    case advanced

    public var displayName: String {
        switch self {
        case .standard: return "标准"
        case .advanced: return "高级"
        }
    }
}

/// Stage2 响应里的 mode 字段（文档 §6.5）。
public enum TranslateMode: String, Codable, CaseIterable, Hashable, Sendable {
    case word
    case sentence
    case ocr
}
