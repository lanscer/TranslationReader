import Foundation

/// 翻译引擎：机器翻译（默认、零配置）与 AI 大模型翻译（需自填端点与密钥）。
///
/// 产品口径（2026-11-06 追加）：**默认走机器翻译**——不填任何东西就能用；
/// AI 翻译作为可选项，保留原有的两阶段（译文 + 词条细节）能力。
public enum TranslationEngineKind: String, Codable, CaseIterable, Hashable, Sendable {
    case machine
    case ai

    public var displayName: String {
        switch self {
        case .machine: return "机器翻译"
        case .ai: return "AI 翻译"
        }
    }

    /// 卡片顶栏等窄位置用。
    public var shortName: String {
        switch self {
        case .machine: return "机器"
        case .ai: return "AI"
        }
    }

    public var summary: String {
        switch self {
        case .machine: return "免密钥、开箱即用；只有译文，没有词条细节"
        case .ai: return "需自填 OpenAI 兼容端点与 Key；有词条 / 例句 / 用法等细节"
        }
    }
}

/// 机器翻译服务商。全部为免密钥公开接口，按顺序回退。
public enum MachineTranslationService: String, Codable, CaseIterable, Hashable, Sendable {
    case auto
    case youdao
    case myMemory = "mymemory"
    case google

    public var displayName: String {
        switch self {
        case .auto: return "自动（有道 → MyMemory → 谷歌）"
        case .youdao: return "有道翻译"
        case .myMemory: return "MyMemory"
        case .google: return "谷歌翻译"
        }
    }

    /// 卡片 / 历史里显示的服务名（自动模式按实际命中回填，这里是兜底文案）。
    public var cardName: String {
        switch self {
        case .auto: return "自动"
        case .youdao: return "有道"
        case .myMemory: return "MyMemory"
        case .google: return "谷歌"
        }
    }

    /// 自动模式的尝试顺序；显式选择时只试它自己。
    public var fallbackChain: [MachineTranslationService] {
        switch self {
        case .auto: return [.youdao, .myMemory, .google]
        case .youdao, .myMemory, .google: return [self]
        }
    }

    /// 单次请求的文本上限（UTF-8 字节）：MyMemory 免费档按 500 字节截断，留一点余量。
    public var requestByteLimit: Int {
        switch self {
        case .youdao: return 3_000
        case .myMemory: return 450
        case .google: return 1_800
        case .auto: return 450
        }
    }

    /// 该服务是否支持源语言「自动检测」。
    public var supportsAutoSource: Bool {
        switch self {
        case .youdao, .google: return true
        case .myMemory, .auto: return false
        }
    }
}
