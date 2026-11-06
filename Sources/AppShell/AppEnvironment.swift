import AppKit
import Combine
import Contracts
import HotkeyKit
import SpeechKit
import Store
import TranslateKit

/// 装配根：把 Store / SpeechKit / TranslateKit / OverlayKit 的实例拼在一起，
/// 各 UI 只从这里取依赖（模块之间仍不互相 import）。
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let toast: ToastCenter
    let keychain: KeychainStore
    let settings: SettingsModel
    let speech: SpeechCoordinator

    private(set) var history: SQLiteHistoryStore?
    private(set) var historyError: String?
    /// apiKey 内存缓存（SettingsModel 持有同一实例；每会话最多读一次钥匙串）。
    private var apiKeyCache: APIKeyCache { settings.apiKeyCache }

    private(set) lazy var card: CardController = CardController(env: self)
    private(set) lazy var historyWindow: HistoryWindowController = HistoryWindowController(env: self)
    private(set) lazy var settingsWindow: SettingsWindowController = SettingsWindowController(env: self)
    private(set) lazy var permissions: PermissionCenter = PermissionCenter(env: self)
    private(set) lazy var hotkeys: HotkeyController = HotkeyController(env: self)
    private(set) lazy var selectionWatcher: SelectionWatcher = SelectionWatcher(env: self)
    private(set) lazy var capture: CaptureFlow = CaptureFlow(env: self)

    private init() {
        let toast = ToastCenter()
        let keychain = KeychainStore()
        let settings = SettingsModel(keychain: keychain)
        self.toast = toast
        self.keychain = keychain
        self.settings = settings
        self.speech = SpeechCoordinator(store: settings.speechStore, toast: toast)

        do {
            self.history = try Store.openDefaultStore()
            self.historyError = nil
        } catch {
            self.history = nil
            self.historyError = String(describing: error)
            AppLog.echo("历史库打开失败：\(error)", AppLog.lifecycle)
        }
    }

    // MARK: - 翻译

    /// 首次调用会读一次钥匙串并缓存；被拒绝后本会话不再重试（避免反复弹窗）。
    func currentAPIKey() -> String? { apiKeyCache.loadIfNeeded() }

    func refreshAPIKey() {
        apiKeyCache.reload()
        settings.refreshAPIKeyState()
    }

    var hasAPIKey: Bool { !(apiKeyCache.loadIfNeeded() ?? "").isEmpty }

    var keychainDenied: Bool { apiKeyCache.isDenied }

    func makeProvider() -> TranslateProvider? {
        makeProvider(engine: settings.settings.translate.engine)
    }

    /// 显式指定引擎：卡片顶栏可以在机器 / AI 之间临时切换，不写回设置。
    func makeProvider(engine: TranslationEngineKind) -> TranslateProvider? {
        let cache = apiKeyCache
        return TranslateKit.makeProvider(settings: settings.settings.translate, engine: engine) {
            // 只读内存快照：绝不在网络请求路径上触发钥匙串读取/弹窗。
            cache.cachedValue()
        }
    }

    /// 语言方向：可写死，也可自动检测；自动时源语言填 auto，交给模型判断。
    func pair(for text: String) -> LanguagePair {
        var pair = settings.settings.lang.defaultPair
        if pair.source == .auto {
            let detected = LanguageHint.detect(text)
            pair.source = detected == pair.target ? .en : .auto
        }
        return pair
    }

    func pairTitle(_ pair: LanguagePair) -> String {
        let source = pair.source == .auto ? "自动检测" : pair.source.displayName
        return source + " · " + pair.target.displayName
    }

    // MARK: - 历史

    func insertHistory(_ entry: HistoryEntry) {
        guard let history else { return }
        do {
            try history.insert(entry)
            try history.trim(to: settings.settings.history.limit)
        } catch {
            AppLog.echo("写历史失败：\(error)", AppLog.lifecycle)
        }
    }

    func recentEntries(limit: Int) -> [HistoryEntry] {
        guard let history else { return [] }
        return (try? history.recent(limit: limit)) ?? []
    }

    func favoriteIDs() -> Set<String> {
        guard let history, let favorites = try? history.favorites() else { return [] }
        return Set(favorites.map(\.id))
    }

    func isFavorite(_ id: String) -> Bool { favoriteIDs().contains(id) }

    func toggleFavorite(_ id: String) {
        guard let history else { return }
        if isFavorite(id) {
            try? history.removeFavorite(historyID: id)
        } else {
            try? history.addFavorite(historyID: id, note: nil, createdAt: Int(Date().timeIntervalSince1970))
        }
    }

    // MARK: - 权限与热键

    var accessibilityGranted: Bool { PermissionCenter.accessibilityGranted }
    var screenRecordingGranted: Bool { PermissionCenter.screenRecordingGranted }

    @discardableResult
    func rebindHotkey(_ action: HotkeyAction) -> Result<HotkeyCombo, HotkeyRegistrationError> {
        hotkeys.rebind(action)
    }
}
