import Foundation
import Contracts

/// 两阶段的 prompt 与请求体（文档 §6.5「Prompt 约束」五条）。
public enum OpenAIPrompt {
    static func languageLabel(_ code: LangCode) -> String {
        code == .auto ? "自动检测" : "\(code.displayName)（\(code.rawValue)）"
    }

    static func modeInstruction(_ mode: TranslateMode) -> String {
        switch mode {
        case .word:
            return "单词/短语模式：给出该词最贴切的词义；有多义时用顿号分隔，不要分组、不要例句、不要括注。"
        case .sentence:
            return "句子模式：给出通顺完整的整句译文，保持原意与语域。"
        case .ocr:
            return "OCR 模式：保留原文的换行结构，逐行对应翻译，不合并行、不增删行。"
        }
    }

    public static func stage1System(_ req: TranslateRequest) -> String {
        """
        你是专业翻译引擎，只做翻译，不聊天。
        硬性要求：
        1. 只输出目标语言的译文本身，不解释、不加引号、不加“译文：”之类前缀；专有名词保留原文。
        2. 源语言：\(languageLabel(req.pair.source))；目标语言：\(languageLabel(req.pair.target))。
        3. \(modeInstruction(req.mode))
        4. 目标语言为中文时默认简体、全角标点；目标语言为英文时使用半角标点。
        5. 不确定的术语或语域不要加在译文里，也不要写括注，留到细节请求中说明。
        """
    }

    public static func stage1User(_ req: TranslateRequest) -> String {
        req.text
    }

    static let stage2Schema = """
    {
      "source_lang": "en",
      "target_lang": "zh-Hans",
      "translation": "……",
      "mode": "word|sentence|ocr",
      "senses": [{"pos": "n.", "defs": [{"def": "鸟；禽", "examples": [{"src": "a bird in the hand", "tgt": "一鸟在手"}]}]}],
      "synonyms": [{"word": "fowl", "note": "家禽"}],
      "usage": [{"title": "give sb. the bird", "body": "起哄、喝倒彩"}],
      "notes": ["口语中也可指年轻女子，注意语域"]
    }
    """

    public static func stage2System(_ req: TranslateRequest, strengthen: Bool) -> String {
        let base = """
        你是词典与翻译细节引擎。只输出一个 JSON 对象，不要 markdown 代码块，不要任何解释文字。
        字段结构（缺省项可给空数组，不得省略 translation / target_lang / mode）：
        \(stage2Schema)
        约束：
        - source_lang / target_lang 用 BCP-47 标签；mode 只能是 word、sentence、ocr 之一。
        - senses 按词性分组，例句必须带 src（原文）与 tgt（译文）。
        - translation 与目标语言一致：\(languageLabel(req.pair.target))；中文默认简体全角标点。
        - 不确定的术语/语域写进 notes，不得在 translation 里加括注。
        """
        if strengthen {
            return base + "\n上一次的返回不是合法 JSON。这次必须只输出一个合法 JSON 对象，不能有代码块围栏或任何前后缀文字。"
        }
        return base
    }

    public static func stage2User(_ req: TranslateRequest, stage1Translation: String) -> String {
        """
        原文：
        \(req.text)

        当前译文（用于对齐 translation 字段，可润色）：
        \(stage1Translation)

        请按 schema 输出细节 JSON。
        """
    }
}

public enum ChatRequestBody {
    public static func data(
        model: String,
        system: String,
        user: String,
        stream: Bool,
        temperature: Double = 0.2
    ) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "stream": stream,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// OpenAI 兼容响应解析。畸形 chunk 一律忽略（不打断流），只有服务端显式 error 才抛出。
public enum ChatResponseDecoder {
    public static func streamDelta(from payload: String) throws -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "服务端返回错误"
            throw AppError.invalidResponse(reason: message)
        }

        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            return nil
        }
        if let delta = first["delta"] as? [String: Any] {
            if let text = delta["content"] as? String { return text.isEmpty ? nil : text }
            if let parts = delta["content"] as? [[String: Any]] {
                let joined = parts.compactMap { $0["text"] as? String }.joined()
                return joined.isEmpty ? nil : joined
            }
        }
        // 部分中转在 stream=true 时直接返回非流式结构。
        if let message = first["message"] as? [String: Any], let text = message["content"] as? String {
            return text.isEmpty ? nil : text
        }
        return nil
    }

    public static func completionsText(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.invalidResponse(reason: "非 JSON 响应")
        }
        if let error = object["error"] as? [String: Any] {
            throw AppError.invalidResponse(reason: (error["message"] as? String) ?? "服务端返回错误")
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            throw AppError.invalidResponse(reason: "缺少 choices")
        }
        if let message = first["message"] as? [String: Any], let text = message["content"] as? String {
            return text
        }
        if let text = first["text"] as? String { return text }
        throw AppError.invalidResponse(reason: "缺少 message.content")
    }
}
