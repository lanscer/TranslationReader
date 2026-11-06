import AppKit
import Combine
import Contracts
import DesignSystem
import TranslateKit

/// 一次翻译会话的全部 UI 状态：原文 / 供编辑的 OCR 确认态 / 流式译文 / 词条细节 / 错误 / tab。
/// 只读原文朗读、译文永不挂喇叭（文档 §1.2 / §12 冻结约束）。
@MainActor
final class TranslationSession: ObservableObject {
    enum Phase: String, Equatable {
        case idle
        case confirm
        case streaming
        case done
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    /// OCR 识别结果编辑态：卡片同时显示「识别结果」与「翻译结果」两栏（不再出引擎/档位选项）。
    @Published private(set) var showsEditor: Bool = false
    @Published private(set) var sourceText: String = ""
    @Published var editableText: String = ""
    @Published private(set) var translationText: String = ""
    @Published private(set) var detail: TranslationDetail?
    @Published private(set) var errorText: String?
    @Published private(set) var errorHint: String?
    @Published private(set) var missingAPIKey: Bool = false
    @Published private(set) var tier: AiTier = .standard
    /// 本次会话使用的翻译引擎：打开卡片时取设置里的默认值，顶栏可临时切换。
    @Published private(set) var engine: TranslationEngineKind = .machine
    @Published private(set) var mode: CardContentMode = .sentence
    @Published private(set) var tabs: [CardTab] = []
    @Published private(set) var selectedTab: Int = 0
    @Published private(set) var sourceKind: SourceKind = .clipboard
    @Published private(set) var pairTitle: String = ""
    @Published private(set) var appBundleID: String?
    @Published private(set) var isFavorite: Bool = false
    @Published private(set) var copiedAt: Date?
    @Published private(set) var canCopyTranslation: Bool = false

    /// 最近一次翻译耗时（首 token / 完成），验收与日志共用。
    @Published private(set) var firstTokenMs: Int?
    @Published private(set) var totalMs: Int?

    unowned let env: AppEnvironment
    var onRequestClose: (() -> Void)?

    private var task: Task<Void, Never>?
    private var entryID = UUID().uuidString
    private var insertAt: Date = Date()

    init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: - 呈现

    func present(text: String, kind: SourceKind, editable: Bool, bundleID: String? = nil) {
        task?.cancel()
        entryID = UUID().uuidString
        sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        editableText = sourceText
        translationText = ""
        detail = nil
        errorText = nil
        errorHint = nil
        missingAPIKey = false
        copiedAt = nil
        canCopyTranslation = false
        firstTokenMs = nil
        totalMs = nil
        sourceKind = kind
        appBundleID = bundleID
        tier = .standard
        engine = env.settings.settings.translate.engine
        insertAt = Date()
        mode = CardDetailLogic.mode(for: sourceText)
        tabs = CardDetailLogic.tabs(for: mode)
        selectedTab = 0
        pairTitle = env.pairTitle(env.pair(for: sourceText))
        isFavorite = env.isFavorite(entryID)
        showsEditor = editable
        phase = .idle
        AppLog.echo("卡片打开 kind=\(kind.rawValue) editable=\(editable) mode=\(mode.rawValue) len=\(sourceText.count)", AppLog.translate)

        // 卡片打开就朗读原文（设置可关）并立刻翻译；
        // OCR 编辑态也一样：识别结果与翻译结果同屏，用户改字后点「翻译并朗读」再重来一次。
        speakIfEnabled()
        startTranslate()
    }

    /// OCR 确认态 → 把（可能改过的）文本作为原文，再翻译 + 朗读。
    func confirmOCR() {
        let text = editableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sourceText = text
        mode = CardDetailLogic.mode(for: text)
        tabs = CardDetailLogic.tabs(for: mode)
        selectedTab = 0
        pairTitle = env.pairTitle(env.pair(for: text))
        phase = .idle
        showsEditor = true
        // 确认时如果文本没改、同一段还在读，就不打断重读；改过才重新朗读。
        speakIfEnabled(skipIfSpeakingSame: true)
        startTranslate()
    }

    func cancelConfirm() {
        task?.cancel()
        onRequestClose?()
    }

    // MARK: - 翻译

    func startTranslate() {
        task?.cancel()
        let text = sourceText
        guard !text.isEmpty else { return }

        // 机器翻译免密钥，直接放行；只有 AI 翻译才要求 apiKey。
        if engine == .ai {
            guard env.hasAPIKey else {
                phase = .failed
                missingAPIKey = true
                if env.keychainDenied {
                    errorText = "钥匙串访问被拒绝：本会话不再自动读取 apiKey。"
                    errorHint = "点「去配置模型」重新填入 key 并保存；钥匙串询问请选「始终允许」"
                } else {
                    errorText = AppError.missingAPIKey.userMessage
                    errorHint = "设置 → 翻译引擎 里填入 apiKey（存 Keychain），或在卡片顶栏切到「机器」"
                }
                record(error: AppError.missingAPIKey.userMessage)
                return
            }
        }
        guard let provider = env.makeProvider(engine: engine) else {
            phase = .failed
            errorText = "端点地址无效，请检查 baseURL（形如 https://api.example.com/v1）。"
            errorHint = engine == .ai ? nil : "也可在卡片顶栏切到「机器」免配置翻译"
            record(error: "invalid baseURL")
            return
        }

        phase = .streaming
        translationText = ""
        detail = nil
        errorText = nil
        errorHint = nil
        missingAPIKey = false
        canCopyTranslation = false
        let pair = env.pair(for: text)
        let requestMode: TranslateMode = mode == .word ? .word : (sourceKind == .ocr ? .ocr : .sentence)
        let request = TranslateRequest(text: text, pair: pair, tier: tier, mode: requestMode)
        let started = DispatchTime.now()
        let host = engine == .ai
            ? OpenAITranslateProvider.completionsURL(baseURL: env.settings.settings.translate.baseURL)?.host
            : nil

        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in provider.translate(request) {
                    if Task.isCancelled { return }
                    switch event {
                    case .delta(let delta):
                        if self.firstTokenMs == nil, !delta.isEmpty {
                            self.firstTokenMs = Self.ms(since: started)
                        }
                        self.translationText += delta
                        self.canCopyTranslation = true
                    case .detail(let value):
                        self.applyDetail(value)
                    }
                }
                if Task.isCancelled { return }
                self.totalMs = Self.ms(since: started)
                if self.translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.phase = .failed
                    self.errorText = self.engine == .machine
                        ? "机器翻译返回了空译文，请点「重新生成」重试。"
                        : "模型返回了空译文，请点「重新生成」重试。"
                } else {
                    self.phase = .done
                }
                if self.detail == nil {
                    let note = self.engine == .machine
                        ? "机器翻译：只有译文，无词条细节（细节 tab 隐藏）"
                        : "Stage2 无细节，细节 tab 隐藏（译文不受影响）"
                    AppLog.echo(note, AppLog.translate)
                }
                self.record(error: nil)
            } catch {
                if Task.isCancelled { return }
                self.applyError(error, host: host)
                self.record(error: self.errorText)
            }
        }
    }

    func retry() {
        if showsEditor { confirmOCR(); return }
        startTranslate()
    }

    func switchTier(_ value: AiTier) {
        guard value != tier else { return }
        tier = value
        if !showsEditor { startTranslate() }
    }

    /// 顶栏「机器 / AI」切换：立即用新引擎重译，不写回默认设置。
    func switchEngine(_ value: TranslationEngineKind) {
        guard value != engine else { return }
        engine = value
        missingAPIKey = false
        if !showsEditor { startTranslate() }
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTab = index
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - 朗读

    func speakOriginal() {
        guard !sourceText.isEmpty else { return }
        env.speech.toggle(sourceText)
    }

    private func speakIfEnabled(skipIfSpeakingSame: Bool = false) {
        guard env.settings.settings.general.autoSpeak else { return }
        if skipIfSpeakingSame, env.speech.isSpeaking, env.speech.speakingText == sourceText { return }
        env.speech.speak(sourceText, lang: LanguageHint.bcp47(sourceText))
    }

    // MARK: - 复制 / 收藏

    func copyTranslation() {
        guard !translationText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translationText, forType: .string)
        copiedAt = Date()
        env.toast.show("译文已复制")
    }

    func copySource() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sourceText, forType: .string)
        env.toast.show("原文已复制")
    }

    func toggleFavorite() {
        env.toggleFavorite(entryID)
        isFavorite = env.isFavorite(entryID)
        env.toast.show(isFavorite ? "已收藏" : "已取消收藏")
    }

    func openSettings() {
        env.settingsWindow.show(selecting: .account)
    }

    func close() {
        cancel()
        env.speech.stop()
        onRequestClose?()
    }

    // MARK: - 内部

    private func applyDetail(_ value: TranslationDetail) {
        detail = value
        if let lang = value.sourceLang, mode == .sentence {
            _ = lang
        }
        mode = CardDetailLogic.mode(for: sourceText, detail: value)
        tabs = CardDetailLogic.tabs(for: mode)
        if selectedTab >= tabs.count { selectedTab = 0 }
    }

    private func applyError(_ error: Error, host: String?) {
        phase = .failed
        let appError: AppError
        if let typed = error as? AppError {
            appError = typed
        } else {
            appError = .unknown(message: error.localizedDescription)
        }
        switch appError {
        case .unauthorized(let reportedHost):
            errorText = "鉴权失败（\(reportedHost ?? host ?? "端点")）：API Key 无效或无权限。"
            errorHint = "检查 apiKey；设置页可「测试连接」"
        case .missingAPIKey:
            missingAPIKey = true
            errorText = appError.userMessage
            errorHint = "设置 → 翻译引擎 里填入 apiKey，或在卡片顶栏切到「机器」"
        case .network(let underlying):
            errorText = "网络错误：\(underlying)"
            errorHint = "端点 \(host ?? "-")，检查网络后可重试"
        case .timeout(let seconds):
            errorText = appError.userMessage
            errorHint = "端点 \(host ?? "-")"
            _ = seconds
        default:
            errorText = appError.userMessage
            errorHint = host.map { "端点 \($0)" }
        }
        AppLog.echo("翻译失败：" + (errorText ?? "?"), AppLog.translate)
    }

    private func record(error: String?) {
        let entry = HistoryEntry(
            id: entryID,
            createdAt: Int(insertAt.timeIntervalSince1970),
            sourceText: sourceText,
            sourceLang: LanguageHint.detect(sourceText),
            targetLang: env.settings.settings.lang.defaultPair.target,
            translation: translationText.isEmpty ? nil : translationText,
            detail: detail,
            tier: engine == .ai ? tier : nil,
            model: engine == .machine
                ? "机器翻译（" + env.settings.settings.translate.machineService.cardName + "）"
                : env.settings.settings.translate.model(for: tier),
            sourceKind: sourceKind,
            appBundleID: appBundleID,
            ocrImagePath: nil,
            error: error
        )
        env.insertHistory(entry)
    }

    /// 仅 --render-evidence 使用：把一段样例直接灌进会话，供离线渲染截图。
    func applyEvidenceSample(
        source: String,
        translation: String,
        detail: TranslationDetail?,
        kind: SourceKind = .selection,
        error: String? = nil,
        confirm: Bool = false,
        engine: TranslationEngineKind = .machine
    ) {
        self.engine = engine
        showsEditor = confirm
        sourceText = source
        editableText = source
        translationText = translation
        self.detail = detail
        mode = CardDetailLogic.mode(for: source, detail: detail)
        tabs = CardDetailLogic.tabs(for: mode)
        selectedTab = 0
        sourceKind = kind
        pairTitle = env.pairTitle(env.pair(for: source))
        canCopyTranslation = !translation.isEmpty
        errorText = error
        errorHint = error == nil ? nil : "端点 api.example.com"
        missingAPIKey = false
        phase = (error == nil || confirm) ? .done : .failed
        firstTokenMs = error == nil ? 312 : nil
        totalMs = error == nil ? 1480 : nil
    }

    private static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
