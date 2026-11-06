import Foundation
import NaturalLanguage

/// 语种判定结果。置信度低于 OcrLanguageDetector.lowConfidenceThreshold 时，
/// UI 应提示「语种可能不准确，可手动切语言方向」（文档 §6.3 / §6.4）。
public struct OcrLanguageGuess: Sendable, Hashable {
    /// 与 Contracts.LangCode 的 rawValue 对齐（ja / ko / en / zh-Hans / zh-Hant …），便于直接切语言方向。
    public let code: String?
    public let confidence: Float

    public init(code: String?, confidence: Float) {
        self.code = code
        self.confidence = confidence
    }

    public var needsManualHint: Bool { confidence < OcrLanguageDetector.lowConfidenceThreshold }
}

/// 字形判定优先、NLLanguageRecognizer 兜底（文档 §6.3「优先 Vision 候选语言 + NLLanguageRecognizer 兜底」）。
/// Vision 的 VNRecognizeTextRequest 只报候选文本、不报语种，因此这里用「字形 + NaturalLanguage + 候选语言集合」组合判定。
/// 返回值统一收敛成 Contracts.LangCode 的短代码，不返回 "ja-JP" 这类带地区的识别语言码。
public enum OcrLanguageDetector {

    public static let lowConfidenceThreshold: Float = 0.6

    public static func detect(text: String,
                              candidates: [String] = ["zh-Hans", "en-US", "ja-JP", "ko-KR"]) -> OcrLanguageGuess {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return OcrLanguageGuess(code: nil, confidence: 0) }

        let counts = scriptCounts(trimmed)
        let total = Swift.max(counts.total, 1)
        let kanaRatio = CGFloat(counts.kana) / CGFloat(total)
        let hangulRatio = CGFloat(counts.hangul) / CGFloat(total)
        let hanRatio = CGFloat(counts.han) / CGFloat(total)

        // NaturalLanguage 只算一次，既做兜底也提供置信度。
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(trimmed.prefix(2000)))
        let dominant = recognizer.dominantLanguage
        let hypotheses = recognizer.languageHypotheses(withMaximum: 8)
        let nlConfidence = dominant.flatMap { hypotheses[$0] }.map(Float.init) ?? 0

        // 1) 假名 / 谚文是排他字形，直接定语种，不看 NaturalLanguage。
        if counts.kana > 0, kanaRatio >= 0.02 {
            return OcrLanguageGuess(code: "ja", confidence: Swift.max(nlConfidence, 0.92))
        }
        if counts.hangul > 0, hangulRatio >= 0.05 {
            return OcrLanguageGuess(code: "ko", confidence: Swift.max(nlConfidence, 0.92))
        }

        // 2) 汉字占主体 → 中文，简繁按字形字表投票（NaturalLanguage 对 zh 的简繁不稳定）。
        if hanRatio >= 0.10 {
            let variant = chineseVariant(of: trimmed)
            let agreed = dominant.map { base($0.rawValue) == "zh" } ?? false
            return OcrLanguageGuess(code: variant, confidence: Swift.max(agreed ? nlConfidence : 0, 0.7))
        }

        // 3) NaturalLanguage 兜底（拉丁/西里尔/阿拉伯等）。
        if let dominant {
            return OcrLanguageGuess(code: base(dominant.rawValue), confidence: nlConfidence)
        }
        if let fallback = candidates.first {
            return OcrLanguageGuess(code: base(fallback), confidence: nlConfidence)
        }
        return OcrLanguageGuess(code: nil, confidence: nlConfidence)
    }

    // MARK: - 内部

    /// "en-US" → "en"，"zh-Hans" → "zh"，"ja-JP" → "ja"。
    static func base(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code))
    }

    /// 简繁：按常用简繁专用字投票；无信号时退回 zh-Hans（默认语言方向）。
    static func chineseVariant(of text: String) -> String {
        var traditional = 0
        var simplified = 0
        for character in text {
            if traditionalMarkers.contains(character) { traditional += 1 }
            if simplifiedMarkers.contains(character) { simplified += 1 }
        }
        return traditional > simplified ? "zh-Hant" : "zh-Hans"
    }

    struct ScriptCounts {
        var total = 0
        var kana = 0
        var hangul = 0
        var han = 0
    }

    static func scriptCounts(_ text: String) -> ScriptCounts {
        var counts = ScriptCounts()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x20 || value == 0x0A || value == 0x09 || value == 0x3000 { continue }
            counts.total += 1
            switch value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: counts.kana += 1
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: counts.hangul += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: counts.han += 1
            default: break
            }
        }
        return counts
    }

    /// 常用繁体/简体专用字，用于简繁投票。
    static let traditionalMarkers: Set<Character> = Set("這個們來為國學發現點時間問題說當經與廣應會將種樣後於對開關實際義體東車長門問間題簡單複雜")
    static let simplifiedMarkers: Set<Character> = Set("这个们来为国学发现点时间问题说当经与广应会将种样后于对开关实际义体东车长门问间题简单复杂")
}
