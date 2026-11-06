import Foundation
import Contracts

/// LangCode / 语言标签 → BCP-47 语音语言（文档 §6.6「语种 → 音色」）。
public enum SpeechLanguage {
    /// 语言标签归一化后的 BCP-47；系统音色与本地模型都按它挂。
    public static func bcp47(_ lang: String) -> String {
        let normalized = lang
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "", "zh", "zh-hans", "zh-cn", "zh-hans-cn", "zh-sg", "cmn": return "zh-CN"
        case "zh-hant", "zh-tw", "zh-hk", "zh-hant-tw": return "zh-TW"
        case "en", "en-us": return "en-US"
        case "en-gb": return "en-GB"
        case "ja", "jp": return "ja-JP"
        case "ko", "kr": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "ru": return "ru-RU"
        case "pt", "pt-br": return "pt-BR"
        case "pt-pt": return "pt-PT"
        case "es": return "es-ES"
        case "it": return "it-IT"
        case "ar": return "ar-SA"
        case "th": return "th-TH"
        case "vi": return "vi-VN"
        default: return lang
        }
    }

    public static func bcp47(_ lang: LangCode) -> String {
        bcp47(lang.rawValue)
    }

    /// 系统音色的 language 是否命中目标语种。
    /// 主语言子标签相同即算命中（zh-CN 与 zh-TW 同属 zh），避免简繁音色互相排除。
    public static func matches(voiceLanguage: String, lang: String) -> Bool {
        let target = bcp47(lang)
        let voice = bcp47(voiceLanguage)
        if voice == target { return true }
        guard let voicePrimary = voice.split(separator: "-").first?.lowercased(),
              let targetPrimary = target.split(separator: "-").first?.lowercased()
        else { return false }
        return voicePrimary == targetPrimary
    }

    /// 本地引擎按语种选模型用的粗分。
    public static func isChinese(_ lang: String) -> Bool {
        bcp47(lang).lowercased().hasPrefix("zh")
    }

    public static func isEnglish(_ lang: String) -> Bool {
        bcp47(lang).lowercased().hasPrefix("en")
    }
}
