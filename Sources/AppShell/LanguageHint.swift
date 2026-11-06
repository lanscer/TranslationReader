import Foundation
import Contracts

/// 原文语种判断（朗读选音色用）。纯启发式，不引入 NaturalLanguage 依赖，
/// 判定顺序：假名 → 谚文 → 西里尔 → 汉字（含简繁）→ 拉丁语种词典 → 默认英文。
enum LanguageHint {
    static func detect(_ raw: String) -> LangCode {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .en }
        let scalars = text.unicodeScalars

        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return .ja }
        if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return .ko }
        if scalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return .ru }
        if scalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) { return .ar }
        if scalars.contains(where: { (0x0E00...0x0E7F).contains($0.value) }) { return .th }
        if scalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }) {
            return containsHant(text) ? .zhHant : .zhHans
        }
        return latinGuess(text) ?? .en
    }

    /// 常见词命中（小样本，只影响朗读音色，不影响翻译）。
    private static func latinGuess(_ text: String) -> LangCode? {
        let lower = " " + text.lowercased() + " "
        let table: [(LangCode, [String])] = [
            (.fr, [" le ", " la ", " les ", " des ", " est ", " une ", " et ", " pour ", " avec ", " je ", " vous "]),
            (.de, [" der ", " die ", " das ", " und ", " ist ", " nicht ", " mit ", " ein ", " eine ", " ich "]),
            (.es, [" el ", " la ", " los ", " las ", " es ", " y ", " que ", " por ", " con ", " una ", " para "]),
            (.pt, [" o ", " a ", " os ", " as ", " é ", " que ", " para ", " com ", " uma ", " não "]),
            (.it, [" il ", " lo ", " gli ", " che ", " per ", " con ", " una ", " sono ", " non "]),
        ]
        var best: (LangCode, Int)?
        for (lang, words) in table {
            let hits = words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            if hits > (best?.1 ?? 0) { best = (lang, hits) }
        }
        guard let best, best.1 >= 2 else { return nil }
        return best.0
    }

    /// 常见繁体字表（抽样，够用来选 zh-TW 音色）。
    private static func containsHant(_ text: String) -> Bool {
        let hant = "為與這個們來時說會對開後應裡發現國學習問題經濟樣讓從還點種實關"
        return text.contains { hant.contains($0) }
    }

    /// 朗读用的 BCP-47。
    static func bcp47(_ text: String) -> String {
        switch detect(text) {
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .en: return "en-US"
        case .ja: return "ja-JP"
        case .ko: return "ko-KR"
        case .fr: return "fr-FR"
        case .de: return "de-DE"
        case .ru: return "ru-RU"
        case .pt: return "pt-BR"
        case .es: return "es-ES"
        case .it: return "it-IT"
        case .ar: return "ar-SA"
        case .th: return "th-TH"
        case .vi: return "vi-VN"
        case .auto: return "en-US"
        }
    }
}
