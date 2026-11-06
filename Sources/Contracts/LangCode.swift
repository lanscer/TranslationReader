import Foundation

/// 文档 §6.4 冻结的语言枚举。rawValue 即 BCP-47 语言标签。
public enum LangCode: String, Codable, CaseIterable, Hashable, Sendable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case ko
    case fr
    case de
    case ru
    case pt
    case es
    case it
    case ar
    case th
    case vi
    case auto

    /// 「全部语言」选择器使用的清单（排除 auto）。
    public static var concreteCases: [LangCode] {
        allCases.filter { $0 != .auto }
    }

    /// 下拉里显示的中文名。
    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁体中文"
        case .en: return "英语"
        case .ja: return "日语"
        case .ko: return "韩语"
        case .fr: return "法语"
        case .de: return "德语"
        case .ru: return "俄语"
        case .pt: return "葡萄牙语"
        case .es: return "西班牙语"
        case .it: return "意大利语"
        case .ar: return "阿拉伯语"
        case .th: return "泰语"
        case .vi: return "越南语"
        case .auto: return "自动检测"
        }
    }

    public var isAuto: Bool { self == .auto }
}

/// 语言方向。目标语言默认简体中文（文档 §6.4）。
public struct LanguagePair: Codable, Hashable, Sendable {
    public var source: LangCode
    public var target: LangCode

    public init(source: LangCode = .auto, target: LangCode = .zhHans) {
        self.source = source
        self.target = target
    }

    public static let `default` = LanguagePair()
}

/// 文档 §6.4 的预设下拉项，顺序即 UI 顺序。
public struct LanguagePairPreset: Codable, Hashable, Sendable, Identifiable {
    public let title: String
    public let pair: LanguagePair

    public var id: String { title }

    public init(title: String, pair: LanguagePair) {
        self.title = title
        self.pair = pair
    }

    public static let all: [LanguagePairPreset] = [
        .init(title: "自动检测", pair: LanguagePair(source: .auto, target: .zhHans)),
        .init(title: "英汉互译", pair: LanguagePair(source: .en, target: .zhHans)),
        .init(title: "日汉互译", pair: LanguagePair(source: .ja, target: .zhHans)),
        .init(title: "韩汉互译", pair: LanguagePair(source: .ko, target: .zhHans)),
        .init(title: "法汉互译", pair: LanguagePair(source: .fr, target: .zhHans)),
        .init(title: "德汉互译", pair: LanguagePair(source: .de, target: .zhHans)),
        .init(title: "俄汉互译", pair: LanguagePair(source: .ru, target: .zhHans)),
        .init(title: "葡汉互译", pair: LanguagePair(source: .pt, target: .zhHans)),
        .init(title: "西汉互译", pair: LanguagePair(source: .es, target: .zhHans)),
    ]
}
