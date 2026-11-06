import Contracts
import Foundation

/// 引擎工厂：设置面板切换引擎时用。
public typealias SpeechEngineFactory = () -> SpeechEngine

/// 朗读总入口（文档 §6.6 失败降级 + §6.6.1 切换即生效）。
///
/// - 引擎选择持久化在 SpeechSettingsStore（AppShell 侧包进 ObservableObject 即可）
/// - setEngine 立刻生效；正在播放时先 stop 再切
/// - 本地/云端引擎失败自动回落系统引擎，并只上报一次
public final class SpeechService: @unchecked Sendable {
    private let store: SpeechSettingsStore
    private let fallbackNotice: (@Sendable (AppError) -> Void)?
    private let lock = NSLock()
    private var engines: [SpeechEngineKind: SpeechEngine] = [:]
    private var fallbackReported = false
    private var activeStreamTask: Task<Void, Never>?

    public init(
        store: SpeechSettingsStore = UserDefaultsSpeechSettingsStore(),
        engines: [SpeechEngineKind: SpeechEngine] = [:],
        fallbackNotice: (@Sendable (AppError) -> Void)? = nil
    ) {
        self.store = store
        self.engines = engines
        self.fallbackNotice = fallbackNotice
    }

    /// 当前引擎档位（持久化值）。
    public var engineKind: SpeechEngineKind {
        store.engineKind
    }

    /// 当前实际使用的引擎实例（不存在则按需创建）。
    public var currentEngine: SpeechEngine {
        engine(for: store.engineKind)
    }

    public func engine(for kind: SpeechEngineKind) -> SpeechEngine {
        lock.lock()
        defer { lock.unlock() }
        if let existing = engines[kind] { return existing }
        let created = SpeechKit.makeEngine(kind: kind) ?? SystemSpeechEngine()
        engines[kind] = created
        return created
    }

    /// 切换引擎：先打断正在播放的引擎，再写设置（下一次 speak 立即用新引擎）。
    public func setEngine(_ kind: SpeechEngineKind) {
        let previous = currentEngine
        previous.stop()
        activeStreamTask?.cancel()
        activeStreamTask = nil
        store.setEngineKind(kind)
    }

    public func stop() {
        currentEngine.stop()
        activeStreamTask?.cancel()
        activeStreamTask = nil
    }

    public func voices(for lang: String) async -> [VoiceOption] {
        await currentEngine.voices(for: lang)
    }

    /// 朗读；本地/云端引擎出错时自动回落系统引擎并上报一次。
    public func speak(_ text: String, lang: String, rate: Float? = nil, volume: Float? = nil) -> AsyncStream<SpeechEvent> {
        let settings = store.speech
        let speechRate = rate ?? settings.rate
        let speechVolume = volume ?? settings.volume
        let voice = VoiceOption(
            id: store.voiceIdentifier(for: lang) ?? "",
            name: "",
            language: SpeechLanguage.bcp47(lang),
            quality: .unknown,
            engine: store.engineKind
        )
        let kind = store.engineKind
        let primary = currentEngine
        let fallback = self.engine(for: .system)

        return AsyncStream { continuation in
            let task = Task { [weak self] in
                var shouldFallback = false
                for await event in primary.speak(text, voice: voice, rate: speechRate, volume: speechVolume) {
                    if case .failed(let error) = event, kind != .system {
                        shouldFallback = true
                        self?.reportFallback(error)
                        break
                    }
                    continuation.yield(event)
                }
                if shouldFallback {
                    for await event in fallback.speak(text, voice: voice, rate: speechRate, volume: speechVolume) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            self.activeStreamTask = task
            continuation.onTermination = { [weak self] _ in
                self?.activeStreamTask?.cancel()
            }
        }
    }

    private func reportFallback(_ error: AppError) {
        lock.lock()
        let shouldReport = !fallbackReported
        fallbackReported = shouldReport
        lock.unlock()
        if shouldReport { fallbackNotice?(error) }
    }
}
