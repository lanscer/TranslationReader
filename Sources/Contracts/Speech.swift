import Foundation

/// 朗读引擎三档（文档 §6.6 / §6.6.1 / §12 已拍板 2）。
public enum SpeechEngineKind: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case sherpa
    case openai

    public var displayName: String {
        switch self {
        case .system: return "系统"
        case .sherpa: return "本地 sherpa-onnx"
        case .openai: return "云端 /audio/speech"
        }
    }

    /// 云端档只在用户填了语音模型时出现。
    public var requiresUserEndpoint: Bool { self == .openai }
}

/// 音色质量档（文档 §6.6「音色列表显示：名称、语言、质量」）。
public enum VoiceQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case `default`
    case enhanced
    case premium
    case unknown

    public var displayName: String {
        switch self {
        case .default: return "default"
        case .enhanced: return "enhanced"
        case .premium: return "premium"
        case .unknown: return "unknown"
        }
    }
}

/// 文档 §6.6 的音色选项。
public struct VoiceOption: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let language: String
    public let quality: VoiceQuality
    public let engine: SpeechEngineKind

    public init(id: String, name: String, language: String, quality: VoiceQuality = .unknown, engine: SpeechEngineKind = .system) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
        self.engine = engine
    }
}

/// 一次朗读的生命周期事件。
public enum SpeechEvent: Equatable, Sendable {
    case started
    /// 已播放到的字符偏移（用于高亮/进度）。
    case boundary(offset: Int)
    case finished
    case failed(AppError)
}

/// 文档 §6.6 冻结的引擎协议（kind 为 §6.6.1 的引擎切换补充字段）。
public protocol SpeechEngine: AnyObject {
    var id: String { get }
    var kind: SpeechEngineKind { get }
    var needsNetwork: Bool { get }
    func voices(for lang: String) async -> [VoiceOption]
    func speak(_ text: String, voice: VoiceOption?, rate: Float, volume: Float) -> AsyncStream<SpeechEvent>
    func stop()
}
