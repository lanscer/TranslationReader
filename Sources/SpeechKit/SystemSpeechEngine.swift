import AVFoundation
import Contracts
import Foundation

/// 系统引擎（文档 §6.6 SystemSpeech）：AVSpeechSynthesizer 封装。
///
/// - voices(for:) 列系统音色（含 language / quality / identifier）
/// - speak 返回 AsyncStream<SpeechEvent>：.started 出声、.boundary 报字符偏移、.finished 收尾
/// - stop() 立即打断当前朗读
/// - rate 为倍速（1.0 = 系统默认语速），volume 0-1，pitch 为音高倍数
public final class SystemSpeechEngine: NSObject, SpeechEngine, @unchecked Sendable {
    public let id = "system"
    public let kind: SpeechEngineKind = .system
    public var needsNetwork: Bool { false }

    /// 音高倍数（0.5-2.0，1.0 为原始音高）。§6.6 协议签名冻结，pitch 落在引擎属性上。
    public var pitch: Float = 1.0

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuations: [ObjectIdentifier: AsyncStream<SpeechEvent>.Continuation] = [:]

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 音色

    public func voices(for lang: String) async -> [VoiceOption] {
        Self.voices(matching: lang)
    }

    /// 同步列举，供设置面板直接使用。
    public static func voices(matching lang: String) -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { SpeechLanguage.matches(voiceLanguage: $0.language, lang: lang) }
            .map { VoiceOption(voice: $0) }
            .sorted { lhs, rhs in
                if qualityRank(lhs.quality) != qualityRank(rhs.quality) {
                    return qualityRank(lhs.quality) > qualityRank(rhs.quality)
                }
                return lhs.name < rhs.name
            }
    }

    /// 目标语种的系统音色；显式指定 identifier 时优先用它。
    public static func resolveVoice(lang: String, preferredIdentifier: String?) -> AVSpeechSynthesisVoice? {
        if let preferredIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: preferredIdentifier) {
            return voice
        }
        if let exact = AVSpeechSynthesisVoice(language: SpeechLanguage.bcp47(lang)) { return exact }
        return AVSpeechSynthesisVoice.speechVoices().first {
            SpeechLanguage.matches(voiceLanguage: $0.language, lang: lang)
        }
    }

    static func qualityRank(_ quality: VoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        case .unknown: return 0
        }
    }

    // MARK: - 朗读

    public func speak(_ text: String, voice: VoiceOption?, rate: Float, volume: Float) -> AsyncStream<SpeechEvent> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AsyncStream { continuation in
                continuation.yield(.finished)
                continuation.finish()
            }
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        if let identifier = voice?.id, let explicit = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = explicit
        } else {
            utterance.voice = Self.resolveVoice(lang: voice?.language ?? "zh-CN", preferredIdentifier: nil)
        }
        utterance.rate = Self.avRate(forMultiplier: rate)
        utterance.volume = min(max(volume, 0), 1)
        utterance.pitchMultiplier = min(max(pitch, 0.5), 2.0)
        utterance.postUtteranceDelay = 0

        let identifier = ObjectIdentifier(utterance)

        return AsyncStream { continuation in
            self.lock.lock()
            self.continuations[identifier] = continuation
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.takeContinuation(identifier)
            }

            self.synthesizer.speak(utterance)
        }
    }

    /// 立即打断：先让合成器停声，再把所有未完成的流就地结束。
    /// AVSpeechSynthesizer 的 didCancel 回调实测滞后约 300ms，不能拿它当「已停」的信号。
    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for (_, continuation) in pending {
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    /// 倍速 → AVSpeechUtterance.rate（系统默认 0.5 视为 1.0x）。
    public static func avRate(forMultiplier multiplier: Float) -> Float {
        let clamped = min(max(multiplier, 0.25), 2.0)
        return min(max(AVSpeechUtteranceDefaultSpeechRate * clamped, 0.01), 1.0)
    }

    private func continuation(for utterance: AVSpeechUtterance) -> AsyncStream<SpeechEvent>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuations[ObjectIdentifier(utterance)]
    }

    @discardableResult
    private func takeContinuation(_ identifier: ObjectIdentifier) -> AsyncStream<SpeechEvent>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuations.removeValue(forKey: identifier)
    }
}

extension SystemSpeechEngine: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        continuation(for: utterance)?.yield(.started)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        continuation(for: utterance)?.yield(.boundary(offset: characterRange.location))
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if let continuation = takeContinuation(ObjectIdentifier(utterance)) {
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if let continuation = takeContinuation(ObjectIdentifier(utterance)) {
            continuation.yield(.finished)
            continuation.finish()
        }
    }
}

extension VoiceOption {
    /// 由系统音色构造音色选项（§6.6「音色列表显示：名称、语言、质量」）。
    public init(voice: AVSpeechSynthesisVoice) {
        self.init(
            id: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: VoiceQuality(voice.quality),
            engine: .system
        )
    }
}

extension VoiceQuality {
    public init(_ quality: AVSpeechSynthesisVoiceQuality) {
        switch quality {
        case .premium: self = .premium
        case .enhanced: self = .enhanced
        case .default: self = .default
        default: self = .unknown
        }
    }
}
