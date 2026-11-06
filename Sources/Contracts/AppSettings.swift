import Foundation

/// 文档 §6.7 的设置树（UserDefaults 持久化，非敏感项）。
/// 敏感项 apiKey 不进这里，走 Keychain（service = bundle id，account = translate.apiKey）。
public struct AppSettings: Codable, Hashable, Sendable {
    public var general: General
    public var translate: Translate
    public var lang: Lang
    public var speech: Speech
    public var selection: Selection
    public var hotkeys: Hotkeys
    public var history: History

    public init(
        general: General = .init(),
        translate: Translate = .init(),
        lang: Lang = .init(),
        speech: Speech = .init(),
        selection: Selection = .init(),
        hotkeys: Hotkeys = .init(),
        history: History = .init()
    ) {
        self.general = general
        self.translate = translate
        self.lang = lang
        self.speech = speech
        self.selection = selection
        self.hotkeys = hotkeys
        self.history = history
    }

    public static let `default` = AppSettings()

    public struct General: Codable, Hashable, Sendable {
        public var launchAtLogin: Bool
        public var autoSpeak: Bool
        public var closeOnBlur: Bool

        public init(launchAtLogin: Bool = false, autoSpeak: Bool = true, closeOnBlur: Bool = true) {
            self.launchAtLogin = launchAtLogin
            self.autoSpeak = autoSpeak
            self.closeOnBlur = closeOnBlur
        }
    }

    public struct Translate: Codable, Hashable, Sendable {
        /// 默认翻译引擎：机器翻译（2026-11-06 起）。AI 翻译为可选项。
        public var engine: TranslationEngineKind
        /// 机器翻译服务商（auto = 按回退链尝试）。
        public var machineService: MachineTranslationService
        /// 机器翻译单次请求超时（毫秒）。
        public var machineTimeoutMs: Int
        public var baseURL: String
        public var modelStandard: String
        public var modelAdvanced: String
        public var timeoutMs: Int
        public var stream: Bool

        public init(
            engine: TranslationEngineKind = .machine,
            machineService: MachineTranslationService = .auto,
            machineTimeoutMs: Int = 8_000,
            baseURL: String = "",
            modelStandard: String = "gpt-4o-mini",
            modelAdvanced: String = "gpt-4o",
            timeoutMs: Int = 25_000,
            stream: Bool = true
        ) {
            self.engine = engine
            self.machineService = machineService
            self.machineTimeoutMs = machineTimeoutMs
            self.baseURL = baseURL
            self.modelStandard = modelStandard
            self.modelAdvanced = modelAdvanced
            self.timeoutMs = timeoutMs
            self.stream = stream
        }

        public func model(for tier: AiTier) -> String {
            switch tier {
            case .standard: return modelStandard
            case .advanced: return modelAdvanced
            }
        }

        // MARK: - 兼容旧设置

        private enum CodingKeys: String, CodingKey {
            case engine, machineService, machineTimeoutMs
            case baseURL, modelStandard, modelAdvanced, timeoutMs, stream
        }

        /// 旧版本存下的 JSON 没有 engine / machineService 字段。
        /// 用 decodeIfPresent 逐字段兜底，避免整份设置（含热键、划词黑名单）被重置。
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            engine = try container.decodeIfPresent(TranslationEngineKind.self, forKey: .engine) ?? .machine
            machineService = try container.decodeIfPresent(MachineTranslationService.self, forKey: .machineService) ?? .auto
            machineTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .machineTimeoutMs) ?? 8_000
            baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
            modelStandard = try container.decodeIfPresent(String.self, forKey: .modelStandard) ?? "gpt-4o-mini"
            modelAdvanced = try container.decodeIfPresent(String.self, forKey: .modelAdvanced) ?? "gpt-4o"
            timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 25_000
            stream = try container.decodeIfPresent(Bool.self, forKey: .stream) ?? true
        }
    }

    public struct Lang: Codable, Hashable, Sendable {
        public enum ZhVariant: String, Codable, CaseIterable, Hashable, Sendable {
            case hans
            case hant
        }

        public var defaultPair: LanguagePair
        public var zhVariant: ZhVariant

        public init(defaultPair: LanguagePair = .default, zhVariant: ZhVariant = .hans) {
            self.defaultPair = defaultPair
            self.zhVariant = zhVariant
        }
    }

    public struct Speech: Codable, Hashable, Sendable {
        public var engine: SpeechEngineKind
        public var rate: Float
        public var volume: Float
        /// key = LangCode.rawValue，value = AVSpeechSynthesisVoice.identifier 等引擎侧音色 id。
        public var voiceByLang: [String: String]

        public init(
            engine: SpeechEngineKind = .system,
            rate: Float = 1.0,
            volume: Float = 0.9,
            voiceByLang: [String: String] = [:]
        ) {
            self.engine = engine
            self.rate = rate
            self.volume = volume
            self.voiceByLang = voiceByLang
        }
    }

    public struct Selection: Codable, Hashable, Sendable {
        public var enabled: Bool
        public var blocklist: [String]

        public init(enabled: Bool = true, blocklist: [String] = ["com.apple.Terminal", "com.apple.keychainaccess"]) {
            self.enabled = enabled
            self.blocklist = blocklist
        }
    }

    public struct Hotkeys: Codable, Hashable, Sendable {
        public var translate: String
        public var capture: String
        public var repeatLast: String

        public init(translate: String = "opt+space", capture: String = "opt+s", repeatLast: String = "opt+r") {
            self.translate = translate
            self.capture = capture
            self.repeatLast = repeatLast
        }

        private enum CodingKeys: String, CodingKey { case translate, capture, repeatLast = "repeat" }
    }

    public struct History: Codable, Hashable, Sendable {
        public var limit: Int

        public init(limit: Int = 2000) {
            self.limit = limit
        }
    }
}
