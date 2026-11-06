import AppKit
import Combine
import Contracts
import SpeechKit

/// 朗读协调器：把 SpeechService 包成 ObservableObject，供卡片/设置/菜单观察。
/// 硬约束：只朗读原文；TTS 失败绝不阻断翻译。
@MainActor
final class SpeechCoordinator: ObservableObject {
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var speakingText: String?
    /// 上一条朗读过的原文（⌥R 复读用）。
    @Published private(set) var lastSpokenText: String?
    @Published private(set) var lastError: String?
    @Published private(set) var engineKind: SpeechEngineKind = .system

    private let store: UserDefaultsSpeechSettingsStore
    private let service: SpeechService
    private var pump: Task<Void, Never>?
    private weak var toast: ToastCenter?

    init(store: UserDefaultsSpeechSettingsStore, toast: ToastCenter) {
        self.store = store
        self.toast = toast
        let notice: @Sendable (AppError) -> Void = { error in
            Task { @MainActor in
                toast.show("朗读引擎已回落到系统引擎：" + error.userMessage, isError: true, seconds: 3.2)
            }
        }
        self.service = SpeechService(store: store, fallbackNotice: notice)
        self.engineKind = store.engineKind
        // 启动时把「当前引擎」写进 store，保证首屏显示的档位与实际一致。
        store.setEngineKind(store.engineKind)
    }

    var rate: Float { store.speech.rate }
    var volume: Float { store.speech.volume }

    // MARK: - 播放

    /// 点击喇叭的语义：正在读同一段 → 立即停；否则从头重读（打断旧的）。
    func toggle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isSpeaking, speakingText == trimmed {
            stop()
        } else {
            speak(trimmed)
        }
    }

    func speak(_ text: String, lang: String? = nil, speakRate: Float? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        let language = lang ?? LanguageHint.bcp47(trimmed)
        isSpeaking = true
        speakingText = trimmed
        lastSpokenText = trimmed
        lastError = nil
        let stream = service.speak(trimmed, lang: language, rate: speakRate, volume: volume)
        pump = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .started:
                    self.isSpeaking = true
                case .finished, .failed:
                    self.isSpeaking = false
                    if case .failed(let error) = event {
                        self.lastError = error.userMessage
                        AppLog.echo("speech 失败：" + error.userMessage, AppLog.speech)
                    }
                case .boundary:
                    break
                }
            }
            await MainActor.run { self?.isSpeaking = false }
        }
    }

    func stop() {
        service.stop()
        pump?.cancel()
        pump = nil
        isSpeaking = false
        speakingText = nil
    }

    // MARK: - 引擎

    /// 切换引擎：先 stop 再写设置；随后用新引擎读一句「引擎已切换」，让切换可被听见（lead 要求 7）。
    func switchEngine(_ kind: SpeechEngineKind) {
        guard kind != engineKind || store.speech.engine != kind else { return }
        service.setEngine(kind)
        engineKind = kind
        store.setEngineKind(kind)
        // sherpa 未部署时这里会立刻触发回落 + toast 一次，属于预期提示。
        if kind == .sherpa && !SpeechKit.isSherpaInstalled() {
            toast?.show("本地 sherpa-onnx 尚未安装，已回落系统引擎（scripts/install-sherpa.sh）", isError: true, seconds: 3.6)
        }
        speak("引擎已切换", lang: "zh-CN")
    }

    func setRate(_ value: Float) {
        store.update { $0.rate = min(max(value, 0.5), 1.5) }
    }

    func setVolume(_ value: Float) {
        store.update { $0.volume = min(max(value, 0), 1) }
    }

    func voiceIdentifier(for lang: String) -> String? {
        store.voiceIdentifier(for: lang)
    }

    func setVoiceIdentifier(_ identifier: String?, for lang: String) {
        store.setVoiceIdentifier(identifier, for: lang)
    }

    func voices(for lang: String) async -> [VoiceOption] {
        await service.voices(for: lang)
    }
}
