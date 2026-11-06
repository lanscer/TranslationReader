import Foundation

/// 文档 §6.5 冻结的翻译请求。
public struct TranslateRequest: Hashable, Sendable {
    public let text: String
    public let pair: LanguagePair
    public let tier: AiTier
    public let mode: TranslateMode

    public init(text: String, pair: LanguagePair, tier: AiTier = .standard, mode: TranslateMode = .sentence) {
        self.text = text
        self.pair = pair
        self.tier = tier
        self.mode = mode
    }
}

/// 文档 §6.5 冻结的流事件：Stage1 增量 + Stage2 结构化细节。
public enum TranslateEvent: Equatable, Sendable {
    case delta(String)
    case detail(TranslationDetail)
}

/// 文档 §6.5 冻结的 Provider 协议。
public protocol TranslateProvider: AnyObject {
    func translate(_ req: TranslateRequest) -> AsyncThrowingStream<TranslateEvent, Error>
}

/// Stage2 结构化细节（字段与文档 §6.5 的 JSON 一一对应）。
public struct TranslationDetail: Codable, Hashable, Sendable {
    public var sourceLang: LangCode?
    public var targetLang: LangCode
    public var translation: String
    public var mode: TranslateMode
    public var senses: [Sense]
    public var synonyms: [Synonym]
    public var usage: [UsageNote]
    public var notes: [String]

    public init(
        sourceLang: LangCode? = nil,
        targetLang: LangCode = .zhHans,
        translation: String = "",
        mode: TranslateMode = .sentence,
        senses: [Sense] = [],
        synonyms: [Synonym] = [],
        usage: [UsageNote] = [],
        notes: [String] = []
    ) {
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.translation = translation
        self.mode = mode
        self.senses = senses
        self.synonyms = synonyms
        self.usage = usage
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case sourceLang = "source_lang"
        case targetLang = "target_lang"
        case translation, mode, senses, synonyms, usage, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceLang = try c.decodeIfPresent(LangCode.self, forKey: .sourceLang)
        targetLang = try c.decodeIfPresent(LangCode.self, forKey: .targetLang) ?? .zhHans
        translation = try c.decodeIfPresent(String.self, forKey: .translation) ?? ""
        mode = try c.decodeIfPresent(TranslateMode.self, forKey: .mode) ?? .sentence
        // 大模型返回的数组字段可能缺失（文档 R6：降级不伤主流程），统一兜底为空。
        senses = try c.decodeIfPresent([Sense].self, forKey: .senses) ?? []
        synonyms = try c.decodeIfPresent([Synonym].self, forKey: .synonyms) ?? []
        usage = try c.decodeIfPresent([UsageNote].self, forKey: .usage) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    /// 词性分组的一条：n. / v. / adj.，内含多个义项。
    public struct Sense: Codable, Hashable, Sendable {
        public var pos: String
        public var defs: [SenseDefinition]

        public init(pos: String, defs: [SenseDefinition] = []) {
            self.pos = pos
            self.defs = defs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pos = try c.decodeIfPresent(String.self, forKey: .pos) ?? ""
            defs = try c.decodeIfPresent([SenseDefinition].self, forKey: .defs) ?? []
        }

        private enum CodingKeys: String, CodingKey { case pos, defs }
    }

    /// 一个义项 + 其例句。
    public struct SenseDefinition: Codable, Hashable, Sendable {
        public var def: String
        public var examples: [ExamplePair]

        public init(def: String, examples: [ExamplePair] = []) {
            self.def = def
            self.examples = examples
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            def = try c.decodeIfPresent(String.self, forKey: .def) ?? ""
            examples = try c.decodeIfPresent([ExamplePair].self, forKey: .examples) ?? []
        }

        private enum CodingKeys: String, CodingKey { case def, examples }
    }

    /// 例句：原文 + 译文。
    public struct ExamplePair: Codable, Hashable, Sendable {
        public var src: String
        public var tgt: String

        public init(src: String, tgt: String) {
            self.src = src
            self.tgt = tgt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            src = try c.decodeIfPresent(String.self, forKey: .src) ?? ""
            tgt = try c.decodeIfPresent(String.self, forKey: .tgt) ?? ""
        }

        private enum CodingKeys: String, CodingKey { case src, tgt }
    }

    /// 近义/近形词。
    public struct Synonym: Codable, Hashable, Sendable {
        public var word: String
        public var note: String?

        public init(word: String, note: String? = nil) {
            self.word = word
            self.note = note
        }
    }

    /// 用法出处。
    public struct UsageNote: Codable, Hashable, Sendable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        }

        private enum CodingKeys: String, CodingKey { case title, body }
    }
}
