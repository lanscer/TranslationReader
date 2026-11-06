import AppKit
import Foundation
import Combine
import Contracts
import SpeechKit
import Store
import TranslateKit

/// 设置面板的数据源：一份 AppSettings + Keychain 里的 apiKey + 测试连接状态。
/// speech 段以 SpeechKit 的 UserDefaultsSpeechSettingsStore 为准，写的时候两边同步，
/// 避免面板显示与 SpeechService 实际读取的设置打架。
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var hasAPIKey: Bool = false
    @Published private(set) var maskedAPIKey: String = ""
    @Published var connectionMessage: String?
    @Published var connectionOK: Bool = false
    @Published var isTestingConnection: Bool = false
    /// GET /models 的结果（保留厂商前缀原文，直接可填）。
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var isFetchingModels: Bool = false
    @Published var modelListMessage: String?
    @Published var modelListOK: Bool = false
    /// 测试连接失败时的完整诊断行（baseURL + 模型 + HTTP 状态 + 网关原文），可整段复制。
    @Published var diagnostic: String?
    @Published var hotkeyMessage: String?
    @Published var launchMessage: String?
    @Published var apiKeyDraft: String = ""
    @Published var blocklistDraft: String = ""
    @Published var recordingAction: HotkeyAction?
    /// 验收/诊断开关：卡片是否显示「首 token / 完成」计时行（默认关）。
    @Published var showTiming: Bool = DebugFlags.showTiming
    /// 密钥存储方式（默认本地文件 0600；钥匙串可选）。
    @Published private(set) var keyStorage: APIKeyStorage = APIKeyStorage.current
    /// 钥匙串里是否还留着旧条目（属性查询，不读密文、不弹密码框）。
    @Published private(set) var legacyKeychainItemExists: Bool = false
    @Published private(set) var isMigratingKey: Bool = false
    @Published var keyStorageMessage: String?

    let store: UserDefaultsSettingsStore
    let speechStore: UserDefaultsSpeechSettingsStore
    let keychain: KeychainStore
    /// apiKey 的内存缓存（每会话最多读一次钥匙串，用户点保存才写）。
    let apiKeyCache: APIKeyCache

    init(
        store: UserDefaultsSettingsStore = UserDefaultsSettingsStore(),
        speechStore: UserDefaultsSpeechSettingsStore = UserDefaultsSpeechSettingsStore(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.store = store
        self.speechStore = speechStore
        self.keychain = keychain
        self.apiKeyCache = APIKeyCache(keychain: keychain)
        var loaded = store.load()
        loaded.speech = speechStore.speech
        self.settings = loaded
        self.keyStorage = apiKeyCache.storageMode
        refreshAPIKeyState()
        refreshLegacyKeychainState()
    }

    // MARK: - 保存

    private func persist() { store.save(settings) }

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        persist()
    }

    // MARK: - 账号 / 模型

    // MARK: - 翻译引擎（机器翻译 = 默认；AI 翻译 = 可选）

    func setEngine(_ value: TranslationEngineKind) {
        update { $0.translate.engine = value }
        connectionMessage = nil
        connectionOK = false
        diagnostic = nil
    }

    func setMachineService(_ value: MachineTranslationService) {
        update { $0.translate.machineService = value }
        connectionMessage = nil
        connectionOK = false
        diagnostic = nil
    }

    func setBaseURL(_ value: String) { update { $0.translate.baseURL = value.trimmingCharacters(in: .whitespacesAndNewlines) } }
    func setModelStandard(_ value: String) { update { $0.translate.modelStandard = value.trimmingCharacters(in: .whitespaces) } }
    func setModelAdvanced(_ value: String) { update { $0.translate.modelAdvanced = value.trimmingCharacters(in: .whitespaces) } }

    func refreshAPIKeyState() {
        let key = apiKeyCache.loadIfNeeded()
        hasAPIKey = !(key ?? "").isEmpty
        if let key, !key.isEmpty {
            maskedAPIKey = key.count <= 8
                ? String(repeating: "•", count: key.count)
                : String(key.prefix(4)) + "••••" + String(key.suffix(4))
        } else {
            maskedAPIKey = ""
        }
    }

    func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try apiKeyCache.store(trimmed.isEmpty ? nil : trimmed)
            if !trimmed.isEmpty { LogSecrets.register(trimmed) }
        } catch {
            connectionMessage = "写入钥匙串失败：\(error)"
            connectionOK = false
        }
        refreshAPIKeyState()
        AppEnvironment.shared.refreshAPIKey()
    }

    /// 「测试连接」：拿真端点跑一次最小 Stage1，报首 token 耗时或错误。
    func testConnection() async {
        isTestingConnection = true
        connectionMessage = nil
        connectionOK = false
        defer { isTestingConnection = false }

        // 机器翻译不需要 key，走独立的自检分支。
        if settings.translate.engine == .machine {
            await testMachineTranslation()
            return
        }

        refreshAPIKeyState()
        guard hasAPIKey else {
            connectionMessage = "尚未填写 apiKey"
            return
        }
        let key = apiKeyCache.loadIfNeeded()
        guard let provider = TranslateKit.makeProvider(settings: settings.translate, apiKey: key) else {
            connectionMessage = "baseURL 无法解析为 /chat/completions 端点"
            return
        }
        let started = DispatchTime.now()
        do {
            var first: String?
            for try await event in provider.translate(TranslateRequest(
                text: "hello world",
                pair: LanguagePair(source: .en, target: .zhHans),
                tier: .standard,
                mode: .sentence
            )) {
                if case .delta(let delta) = event, !delta.isEmpty {
                    first = delta
                    break
                }
            }
            let ms = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            connectionOK = true
            connectionMessage = "连接成功：首 token \(ms)ms" + (first.map { "，返回「" + String($0.prefix(16)) + "」" } ?? "")
        } catch {
            connectionOK = false
            connectionMessage = (error as? AppError)?.userMessage ?? String(describing: error)
            diagnostic = Self.diagnosticLine(
                baseURL: settings.translate.baseURL,
                model: settings.translate.model(for: .standard),
                error: error
            )
        }
    }

    /// 机器翻译自检：不依赖 apiKey，直接跑一次「hello world」。
    private func testMachineTranslation() async {
        guard let provider = TranslateKit.makeProvider(settings: settings.translate, engine: .machine) else {
            connectionMessage = "机器翻译 Provider 构造失败"
            return
        }
        let started = DispatchTime.now()
        do {
            var first: String?
            for try await event in provider.translate(TranslateRequest(
                text: "hello world",
                pair: LanguagePair(source: .en, target: .zhHans),
                tier: .standard,
                mode: .sentence
            )) {
                if case .delta(let delta) = event, !delta.isEmpty {
                    first = delta
                    break
                }
            }
            let ms = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            connectionOK = true
            connectionMessage = "机器翻译可用：\(ms)ms" + (first.map { "，返回「" + String($0.prefix(20)) + "」" } ?? "")
        } catch {
            connectionOK = false
            let message = (error as? AppError)?.userMessage ?? String(describing: error)
            connectionMessage = message
            diagnostic = "机器翻译=" + settings.translate.machineService.displayName + " | 错误=" + message
        }
    }

    /// 失败诊断行：把端点、模型名、错误类型与网关原文拼成一行，便于整段复制。
    static func diagnosticLine(baseURL: String, model: String, error: Error) -> String {
        if let catalogError = error as? ModelCatalogError {
            return catalogError.diagnostic(baseURL: baseURL, modelName: model)
        }
        let typed = (error as? AppError) ?? .unknown(message: String(describing: error))
        var parts = ["baseURL=\(baseURL.isEmpty ? "(未填)" : baseURL)", "模型=\(model)"]
        switch typed {
        case .unauthorized(let host):
            parts.append("HTTP 401/403")
            parts.append("鉴权失败=\(host ?? "端点")")
        case .network(let underlying):
            parts.append("错误=网络：\(underlying)")
        case .timeout(let seconds):
            parts.append("错误=超时\(seconds.map { " \(Int($0))s" } ?? "")")
        case .invalidResponse(let reason):
            parts.append("错误=响应不合法：\(reason)")
        case .missingAPIKey:
            parts.append("错误=未配置 apiKey")
        default:
            parts.append("错误=\(typed.userMessage)")
        }
        parts.append("提示=多数网关要求厂商前缀，如 deepseek/deepseek-v4.1-flash")
        return parts.joined(separator: " | ")
    }

    /// 「拉取模型列表」：GET {baseURL}/models，带当前 key。
    func fetchModels() async {
        guard !isFetchingModels else { return }
        isFetchingModels = true
        modelListMessage = nil
        modelListOK = false
        diagnostic = nil
        defer { isFetchingModels = false }

        let key = apiKeyCache.loadIfNeeded()
        let result = await ModelCatalogClient.fetch(baseURL: settings.translate.baseURL, apiKey: key)
        switch result {
        case .success(let catalog):
            availableModels = catalog.models
            modelListOK = true
            modelListMessage = "拉到 \(catalog.models.count) 个模型（\(catalog.elapsedMs)ms）"
            // 当前填的裸名不在列表里、且列表里存在唯一后缀匹配时，直接提示正确写法。
            let standard = settings.translate.modelStandard
            if !standard.isEmpty, !catalog.models.contains(standard),
               let hint = catalog.models.first(where: { $0.hasSuffix("/" + standard) }) {
                modelListMessage = "拉到 \(catalog.models.count) 个模型；「\(standard)」应写作「\(hint)」"
            }
            AppLog.echo("models 拉取成功 \(catalog.models.count) 个：\(catalog.endpoint)", AppLog.menu)
        case .failure(let error):
            availableModels = []
            modelListOK = false
            modelListMessage = error.userMessage
            diagnostic = error.diagnostic(baseURL: settings.translate.baseURL, modelName: settings.translate.model(for: .standard))
            AppLog.echo("models 拉取失败：" + error.userMessage, AppLog.menu)
        }
    }

    func copyDiagnostic() {
        guard let diagnostic else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnostic, forType: .string)
        AppEnvironment.shared.toast.show("诊断信息已复制")
    }

    /// 仅 --render-evidence 使用：直接改展示值，不落盘。
    func applyEvidenceModelNames(standard: String, advanced: String) {
        settings.translate.modelStandard = standard
        settings.translate.modelAdvanced = advanced
    }

    /// 仅 --render-evidence 使用：改内存里的引擎，不落盘（避免跑取证时改用户设置）。
    func applyEvidenceEngine(_ value: TranslationEngineKind) {
        settings.translate.engine = value
    }

    func applyEvidenceBaseURL(_ value: String) {
        settings.translate.baseURL = value
    }

    func applyEvidenceLegacyKeychain(_ exists: Bool) {
        legacyKeychainItemExists = exists
    }

    /// 仅 --render-evidence 使用：把一段样例灌进面板，用于离线渲染两态截图。
    func applyEvidence(modelList: [String]?, diagnostic: String?, message: String?) {
        if let modelList {
            availableModels = modelList
            modelListOK = !modelList.isEmpty
        }
        self.diagnostic = diagnostic
        if let message { modelListMessage = message }
        if let diagnostic {
            modelListOK = false
            connectionOK = false
            connectionMessage = message
            _ = diagnostic
        }
    }

    // MARK: - 通用

    func setAutoSpeak(_ value: Bool) { update { $0.general.autoSpeak = value } }
    func setCloseOnBlur(_ value: Bool) { update { $0.general.closeOnBlur = value } }

    // MARK: - 密钥存储方式与迁移

    func refreshLegacyKeychainState() {
        legacyKeychainItemExists = APIKeyCache.legacyKeychainItemExists()
    }

    func setKeyStorage(_ mode: APIKeyStorage, keychain: KeychainStore? = nil) {
        keyStorage = mode
        apiKeyCache.setStorageMode(mode)
        if mode == .file {
            keyStorageMessage = "已切到本地文件（0600）。若刚切换，请重新填入一次 apiKey。"
        } else {
            keyStorageMessage = "已切到钥匙串模式：读取时系统可能要求授权（本项目已改用稳定签名，正常情况下只问一次）。"
        }
        refreshAPIKeyState()
    }

    /// 「从钥匙串导入并删除旧条目」：用户点一次，最多弹一次密码框，之后不再碰钥匙串。
    func importFromKeychainAndDelete() {
        guard !isMigratingKey else { return }
        isMigratingKey = true
        keyStorageMessage = "正在读取钥匙串…（可能会弹一次密码框）"
        do {
            let migrated = try apiKeyCache.migrateFromKeychain()
            keyStorage = .file
            refreshAPIKeyState()
            refreshLegacyKeychainState()
            keyStorageMessage = migrated
                ? "已导入到本地文件并删除旧钥匙串条目；此后不再访问钥匙串。"
                : "钥匙串里没有可导入的密钥（旧条目已清理），请重新填入 apiKey。"
        } catch {
            keyStorageMessage = "导入失败/被取消：\(error)。请直接在下方重新填入 apiKey（本地文件模式不需要钥匙串授权）。"
        }
        isMigratingKey = false
    }

    /// 钥匙串被拒绝时的一句话提示（设置页与卡片共用）。
    var keychainDeniedHint: String? {
        apiKeyCache.isDenied ? "钥匙串访问被拒绝：本会话不再自动读取。请在上方重新填入 apiKey 并点「保存」。" : nil
    }

    func retryKeychainRead() {
        apiKeyCache.forgetDenial()
        refreshAPIKeyState()
    }

    func setShowTiming(_ value: Bool) {
        showTiming = value
        DebugFlags.setShowTiming(value)
    }
    func setLaunchAtLogin(_ value: Bool) { update { $0.general.launchAtLogin = value } }

    var defaultPair: LanguagePair {
        get { settings.lang.defaultPair }
        set { update { $0.lang.defaultPair = newValue } }
    }

    // MARK: - 快捷键

    func combo(for action: HotkeyAction) -> String {
        switch action {
        case .translate: return settings.hotkeys.translate
        case .capture: return settings.hotkeys.capture
        case .repeatLast: return settings.hotkeys.repeatLast
        }
    }

    func setCombo(_ combo: String, for action: HotkeyAction) {
        update { settings in
            switch action {
            case .translate: settings.hotkeys.translate = combo
            case .capture: settings.hotkeys.capture = combo
            case .repeatLast: settings.hotkeys.repeatLast = combo
            }
        }
    }

    // MARK: - 朗读（走 speechStore，两处同步）

    func updateSpeech(_ mutate: (inout AppSettings.Speech) -> Void) {
        speechStore.update(mutate)
        settings.speech = speechStore.speech
        persist()
    }

    // MARK: - 划词

    func setSelectionEnabled(_ value: Bool) {
        update { $0.selection.enabled = value }
        AppEnvironment.shared.selectionWatcher.restartIfNeeded()
    }

    func addBlocklistEntry(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.selection.blocklist.contains(trimmed) else { return }
        update { $0.selection.blocklist.append(trimmed) }
    }

    func removeBlocklistEntry(_ bundleID: String) {
        update { $0.selection.blocklist.removeAll { $0 == bundleID } }
    }

    // MARK: - 历史

    func setHistoryLimit(_ value: Int) { update { $0.history.limit = max(50, min(value, 20000)) } }
}

/// 三个可录制动作（文档 §7）。
enum HotkeyAction: String, CaseIterable, Identifiable {
    case translate
    case capture
    case repeatLast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate: return "翻译选区 / 剪贴板"
        case .capture: return "截图 OCR 翻译"
        case .repeatLast: return "复读上一条"
        }
    }
}

extension Notification.Name {
    static let hotkeysChanged = Notification.Name("TranslationReader.hotkeysChanged")
}
