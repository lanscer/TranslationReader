import AppKit
import SwiftUI
import ServiceManagement
import Combine
import Contracts
import DesignSystem
import HotkeyKit
import SpeechKit
import Store
import TranslateKit

/// 设置窗的 tab 选中项（窗口控制器与视图共享，避免 SwiftUI 宏）。
@MainActor
final class SettingsTabsModel: ObservableObject {
    @Published var index: Int = SettingsPage.account.rawValue
}

/// 设置窗口（文档 §3.5）：翻译引擎 · 通用 · 快捷键 · 朗读 · 划词 · 历史 · 关于。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let env: AppEnvironment
    let tabs = SettingsTabsModel()

    init(env: AppEnvironment) {
        self.env = env
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TranslationReader 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsRootView(env: env, tabs: tabs))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(selecting page: SettingsPage) {
        env.settings.refreshAPIKeyState()
        tabs.index = page.rawValue
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsPage: Int, CaseIterable {
    case account = 0, general, hotkey, speech, selection, history, about

    var title: String {
        switch self {
        case .account: return "翻译引擎"
        case .general: return "通用"
        case .hotkey: return "快捷键"
        case .speech: return "朗读"
        case .selection: return "划词"
        case .history: return "历史"
        case .about: return "关于"
        }
    }
}

struct SettingsRootView: View {
    private let env: AppEnvironment
    @ObservedObject private var model: SettingsModel
    @ObservedObject private var speech: SpeechCoordinator
    @ObservedObject private var tabs: SettingsTabsModel
    @StateObject private var speechPage: SpeechPageModel

    init(env: AppEnvironment, tabs: SettingsTabsModel) {
        self.env = env
        self.model = env.settings
        self.speech = env.speech
        self.tabs = tabs
        _speechPage = StateObject(wrappedValue: SpeechPageModel(env: env))
    }

    var body: some View {
        TabView(selection: Binding(get: { tabs.index }, set: { tabs.index = $0 })) {
            AccountSettingsPage(model: model)
                .tabItem { Text(SettingsPage.account.title) }
                .tag(SettingsPage.account.rawValue)
            GeneralSettingsPage(model: model)
                .tabItem { Text(SettingsPage.general.title) }
                .tag(SettingsPage.general.rawValue)
            HotkeySettingsPage(model: model, env: env)
                .tabItem { Text(SettingsPage.hotkey.title) }
                .tag(SettingsPage.hotkey.rawValue)
            SpeechSettingsPage(model: model, page: speechPage, speech: speech)
                .tabItem { Text(SettingsPage.speech.title) }
                .tag(SettingsPage.speech.rawValue)
            SelectionSettingsPage(model: model, env: env)
                .tabItem { Text(SettingsPage.selection.title) }
                .tag(SettingsPage.selection.rawValue)
            HistorySettingsPage(model: model, env: env)
                .tabItem { Text(SettingsPage.history.title) }
                .tag(SettingsPage.history.rawValue)
            AboutSettingsPage(model: model, env: env)
                .tabItem { Text(SettingsPage.about.title) }
                .tag(SettingsPage.about.rawValue)
        }
        .padding(12)
        .frame(minWidth: 700, minHeight: 490)
    }
}

// MARK: - 账号 / 模型

struct AccountSettingsPage: View {
    @ObservedObject var model: SettingsModel

    private var engine: TranslationEngineKind { model.settings.translate.engine }

    var body: some View {
        Form {
            Section("翻译引擎") {
                Picker("默认引擎", selection: Binding(
                    get: { model.settings.translate.engine },
                    set: { model.setEngine($0) })) {
                    Text("机器翻译（免密钥，默认）").tag(TranslationEngineKind.machine)
                    Text("AI 翻译（需端点与 Key）").tag(TranslationEngineKind.ai)
                }
                .pickerStyle(.radioGroup)

                Text("机器翻译：免密钥、开箱即用，只有译文。AI 翻译：需自填 OpenAI 兼容端点与 Key，另有词条 / 例句 / 用法。卡片顶栏可随时在「机器 / AI」之间临时切换。")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if engine == .machine {
                Section("机器翻译（免密钥）") {
                    Picker("服务商", selection: Binding(
                        get: { model.settings.translate.machineService },
                        set: { model.setMachineService($0) })) {
                        ForEach(MachineTranslationService.allCases, id: \.self) { service in
                            Text(service.displayName).tag(service)
                        }
                    }

                    HStack {
                        Button(model.isTestingConnection ? "测试中…" : "测试机器翻译") {
                            Task { await model.testConnection() }
                        }
                        .disabled(model.isTestingConnection)
                        Spacer(minLength: 0)
                        if let message = model.connectionMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(model.connectionOK ? Color.green : DSColor.danger)
                                .lineLimit(2)
                                .frame(maxWidth: 380, alignment: .trailing)
                        }
                    }

                    Text("公开免密钥接口，按顺序回退：有道（国内最快）→ MyMemory → 谷歌（需海外网络）。机器翻译只有译文；词条 / 例句 / 用法等细节请切到 AI 翻译。")
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let diagnostic = model.diagnostic {
                        Text(diagnostic)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DSColor.danger)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Section("端点与密钥（仅 AI 翻译）") {
                    TextField("baseURL", text: Binding(get: { model.settings.translate.baseURL }, set: { model.setBaseURL($0) }))
                        .textFieldStyle(.roundedBorder)
                        .help("OpenAI 兼容端点，例如 https://api.example.com/v1（会自动补 /chat/completions）")
                    HStack {
                        SecureField("apiKey（存 Keychain，不落明文）", text: $model.apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("保存") {
                            model.saveAPIKey(model.apiKeyDraft)
                            model.apiKeyDraft = ""
                            model.connectionMessage = model.hasAPIKey ? "已写入 Keychain" : "已清除"
                            model.connectionOK = model.hasAPIKey
                        }
                    }
                    LabeledContent("当前密钥", value: model.hasAPIKey ? model.maskedAPIKey : "未配置")
                    if let denied = model.keychainDeniedHint {
                        HStack(spacing: 8) {
                            Text(denied)
                                .font(.system(size: 11))
                                .foregroundStyle(DSColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("重新读取钥匙串") { model.retryKeychainRead() }
                                .font(.system(size: 11))
                        }
                    }
                    Picker("密钥存储方式", selection: Binding(
                        get: { model.keyStorage },
                        set: { model.setKeyStorage($0) })) {
                        ForEach(APIKeyStorage.allCases) { storage in
                            Text(storage.title).tag(storage)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if model.legacyKeychainItemExists {
                        HStack(spacing: 8) {
                            Text("检测到钥匙串里还留着旧条目")
                                .font(.system(size: 11))
                                .foregroundStyle(DSColor.danger)
                            Button(model.isMigratingKey ? "导入中…" : "从钥匙串导入并删除旧条目") {
                                model.importFromKeychainAndDelete()
                            }
                            .font(.system(size: 11))
                            .disabled(model.isMigratingKey)
                        }
                    }
                    if let message = model.keyStorageMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(DSColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("本地文件：~/Library/Application Support/TranslationReader/apikey.bin（0600、父目录 0700、临时文件 + rename 原子替换）。内容只做轻量混淆——防肩窥，不防本地取证。本会话内 apiKey 只读一次并缓存在内存。")
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("模型（标准 / 高级）") {
                    TextField("示例：deepseek/deepseek-v4.1-flash（多数网关要求厂商前缀）",
                              text: Binding(get: { model.settings.translate.modelStandard }, set: { model.setModelStandard($0) }))
                        .textFieldStyle(.roundedBorder)
                    TextField("示例：deepseek/deepseek-v4.2-pro（多数网关要求厂商前缀）",
                              text: Binding(get: { model.settings.translate.modelAdvanced }, set: { model.setModelAdvanced($0) }))
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button(model.isFetchingModels ? "拉取中…" : "拉取模型列表") {
                            Task { await model.fetchModels() }
                        }
                        .disabled(model.isFetchingModels || model.settings.translate.baseURL.isEmpty)

                        Menu("标准档选…") {
                            ForEach(model.availableModels, id: \.self) { name in
                                Button(name) { model.setModelStandard(name) }
                            }
                        }
                        .disabled(model.availableModels.isEmpty)

                        Menu("高级档选…") {
                            ForEach(model.availableModels, id: \.self) { name in
                                Button(name) { model.setModelAdvanced(name) }
                            }
                        }
                        .disabled(model.availableModels.isEmpty)

                        Spacer(minLength: 0)
                        if let message = model.modelListMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(model.modelListOK ? Color.green : DSColor.danger)
                                .lineLimit(2)
                                .frame(maxWidth: 320, alignment: .trailing)
                        }
                    }

                    HStack {
                        Button(model.isTestingConnection ? "测试中…" : "测试连接") {
                            Task { await model.testConnection() }
                        }
                        .disabled(model.isTestingConnection)
                        Spacer(minLength: 0)
                        if let message = model.connectionMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(model.connectionOK ? Color.green : DSColor.danger)
                                .lineLimit(2)
                                .frame(maxWidth: 360, alignment: .trailing)
                        }
                    }

                    if let diagnostic = model.diagnostic {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("诊断信息（可整段复制给对方排查）")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DSColor.textSecondary)
                            Text(diagnostic)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DSColor.danger)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("复制诊断信息") { model.copyDiagnostic() }
                                .font(.system(size: 11))
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: DSMetric.buttonCorner, style: .continuous)
                                .fill(DSColor.surfaceSunken)
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 通用

struct GeneralSettingsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("行为") {
                Toggle("弹窗打开时自动朗读原文", isOn: Binding(get: { model.settings.general.autoSpeak }, set: { model.setAutoSpeak($0) }))
                Toggle("失焦自动关闭弹窗", isOn: Binding(get: { model.settings.general.closeOnBlur }, set: { model.setCloseOnBlur($0) }))
                Toggle("显示性能指标（首 token / 完成耗时）", isOn: Binding(get: { model.showTiming }, set: { model.setShowTiming($0) }))
                Toggle("开机自启", isOn: Binding(get: { model.settings.general.launchAtLogin }, set: { value in
                    model.setLaunchAtLogin(value)
                    model.launchMessage = LaunchAtLogin.set(enabled: value)
                }))
                if let message = model.launchMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
            Section("默认语言方向") {
                Picker("预设", selection: Binding(
                    get: { model.settings.lang.defaultPair.source.rawValue + ">" + model.settings.lang.defaultPair.target.rawValue },
                    set: { value in
                        let parts = value.split(separator: ">").map(String.init)
                        guard parts.count == 2,
                              let source = LangCode(rawValue: parts[0]),
                              let target = LangCode(rawValue: parts[1]) else { return }
                        model.defaultPair = LanguagePair(source: source, target: target)
                    })) {
                    ForEach(LanguagePairPreset.all) { preset in
                        Text(preset.title).tag(preset.pair.source.rawValue + ">" + preset.pair.target.rawValue)
                    }
                }
                Picker("源语言", selection: Binding(
                    get: { model.settings.lang.defaultPair.source },
                    set: { model.defaultPair = LanguagePair(source: $0, target: model.settings.lang.defaultPair.target) })) {
                    ForEach(LangCode.allCases, id: \.self) { code in
                        Text(code.displayName).tag(code)
                    }
                }
                Picker("目标语言", selection: Binding(
                    get: { model.settings.lang.defaultPair.target },
                    set: { model.defaultPair = LanguagePair(source: model.settings.lang.defaultPair.source, target: $0) })) {
                    ForEach(LangCode.concreteCases, id: \.self) { code in
                        Text(code.displayName).tag(code)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 开机自启（SMAppService 只在 .app 里有效，裸二进制给可读提示）。
enum LaunchAtLogin {
    static func set(enabled: Bool) -> String {
        guard Bundle.main.bundleIdentifier != nil else {
            return "当前以裸二进制运行，开机自启仅对 TranslationReader.app 生效"
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                return "已加入登录项"
            } else {
                try SMAppService.mainApp.unregister()
                return "已移出登录项"
            }
        } catch {
            return "登录项设置失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 快捷键

struct HotkeySettingsPage: View {
    @ObservedObject var model: SettingsModel
    let env: AppEnvironment

    var body: some View {
        Form {
            Section("全局热键（Carbon，无需输入监控权限）") {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer(minLength: 8)
                        Text(display(model.combo(for: action)))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DSColor.accent)
                        Button(model.recordingAction == action ? "按下新键…" : "录制") {
                            start(action)
                        }
                        .disabled(model.recordingAction != nil && model.recordingAction != action)
                    }
                }
                if let message = model.hotkeyMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.danger)
                }
                Button("恢复默认（⌥Space / ⌥S / ⌥R）") {
                    model.setCombo("opt+space", for: .translate)
                    model.setCombo("opt+s", for: .capture)
                    model.setCombo("opt+r", for: .repeatLast)
                    model.hotkeyMessage = nil
                    env.hotkeys.registerAll()
                }
            }
            Section("冲突规则") {
                Text("录制后立刻重新注册；被系统或其他 App 占用会报「系统拒绝注册」，本进程内重复会报「冲突」。")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
                ForEach(Array(env.hotkeys.failures.keys), id: \.self) { action in
                    if let message = env.hotkeys.failures[action] {
                        Text(action.title + "：" + message)
                            .font(.system(size: 11))
                            .foregroundStyle(DSColor.danger)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func display(_ combo: String) -> String {
        guard let parsed = HotkeyCombo(string: combo) else { return combo }
        return parsed.displayString
    }

    private func start(_ action: HotkeyAction) {
        model.recordingAction = action
        model.hotkeyMessage = nil
        let recorder = HotkeyRecorder()
        HotkeyRecorderBox.shared.recorder = recorder
        recorder.onFinish = { outcome in
            Task { @MainActor in
                HotkeyRecorderBox.shared.recorder = nil
                model.recordingAction = nil
                guard case .captured(let combo) = outcome else { return }
                for other in HotkeyAction.allCases where other != action {
                    if model.combo(for: other) == combo.string {
                        model.hotkeyMessage = "「\(combo.string)」已被「\(other.title)」占用"
                        return
                    }
                }
                let previous = model.combo(for: action)
                model.setCombo(combo.string, for: action)
                switch env.rebindHotkey(action) {
                case .success:
                    model.hotkeyMessage = nil
                case .failure(let error):
                    model.setCombo(previous, for: action)
                    env.hotkeys.registerAll()
                    model.hotkeyMessage = "注册失败：" + (error.errorDescription ?? String(describing: error))
                }
            }
        }
        if !recorder.start() {
            model.recordingAction = nil
            model.hotkeyMessage = "无法开始录制（窗口不是 key window？）"
        }
    }
}

@MainActor
final class HotkeyRecorderBox {
    static let shared = HotkeyRecorderBox()
    var recorder: HotkeyRecorder?
}

// MARK: - 朗读

@MainActor
final class SpeechPageModel: ObservableObject {
    @Published var engine: SpeechEngineKind
    @Published var sherpaModelID: String
    @Published var rate: Float
    @Published var volume: Float
    @Published var voices: [String: [VoiceOption]] = [:]
    @Published var locked: [String: String] = [:]
    @Published var isLoadingVoices = false
    @Published var notice: String?

    private unowned let env: AppEnvironment
    static let lockLanguages: [LangCode] = [.zhHans, .en, .ja, .ko, .fr, .de, .ru, .pt, .es]

    init(env: AppEnvironment) {
        self.env = env
        self.engine = env.speech.engineKind
        self.sherpaModelID = SherpaModelPreference.load().modelID
        self.rate = env.speech.rate
        self.volume = env.speech.volume
        for lang in Self.lockLanguages {
            locked[lang.rawValue] = env.speech.voiceIdentifier(for: lang.rawValue)
        }
        Task { await loadVoices() }
    }

    func loadVoices() async {
        isLoadingVoices = true
        var result: [String: [VoiceOption]] = [:]
        for lang in Self.lockLanguages {
            result[lang.rawValue] = await env.speech.voices(for: lang.rawValue)
        }
        voices = result
        isLoadingVoices = false
    }

    func switchEngine(_ kind: SpeechEngineKind) {
        engine = kind
        env.speech.switchEngine(kind)
        Task { await loadVoices() }
    }

    func setSherpaModel(_ id: String) {
        sherpaModelID = id
        var pref = SherpaModelPreference.load()
        pref.modelID = id
        pref.save()
        notice = "sherpa 模型已切换到「\(SherpaModelCatalog.spec(id: id)?.displayName ?? id)」"
    }

    func setRate(_ value: Float) {
        rate = value
        env.speech.setRate(value)
    }

    func setVolume(_ value: Float) {
        volume = value
        env.speech.setVolume(value)
    }

    func setLock(_ identifier: String, for lang: LangCode) {
        locked[lang.rawValue] = identifier
        env.speech.setVoiceIdentifier(identifier.isEmpty ? nil : identifier, for: lang.rawValue)
    }

    func preview(_ lang: LangCode) {
        let samples: [LangCode: String] = [
            .zhHans: "这是原文朗读的试听。",
            .en: "This is a preview of reading the original text.",
            .ja: "これは原文読み上げの試聴です。",
            .ko: "이것은 원문 낭독 미리듣기입니다.",
            .fr: "Ceci est un aperçu de la lecture.",
            .de: "Dies ist eine Hörprobe der Vorlesefunktion.",
            .ru: "Это прослушивание озвучивания текста.",
            .pt: "Esta é uma prévia da leitura em voz alta.",
            .es: "Esta es una muestra de la lectura en voz alta.",
        ]
        env.speech.speak(samples[lang] ?? "preview", lang: lang.rawValue)
    }
}

struct SpeechSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var page: SpeechPageModel
    @ObservedObject var speech: SpeechCoordinator

    var body: some View {
        Form {
            Section("引擎（切换立即生效，正在播报会先停）") {
                Picker("", selection: Binding(get: { page.engine }, set: { page.switchEngine($0) })) {
                    Text("系统").tag(SpeechEngineKind.system)
                    Text("本地 sherpa-onnx").tag(SpeechEngineKind.sherpa)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LabeledContent("sherpa 部署", value: SpeechKit.isSherpaInstalled() ? "已安装" : "未安装（scripts/install-sherpa.sh）")
                if page.engine == .sherpa {
                    Picker("模型", selection: Binding(get: { page.sherpaModelID }, set: { page.setSherpaModel($0) })) {
                        ForEach(SherpaModelCatalog.all) { spec in
                            Text(spec.displayName).tag(spec.id)
                        }
                    }
                    if let notice = page.notice {
                        Text(notice).font(.system(size: 11)).foregroundStyle(DSColor.textSecondary)
                    }
                    Text("本地模型只覆盖中文（华研/Matcha）与英文（Amy）；日/韩/法/德/俄/葡/西会自动回落系统引擎。")
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.textSecondary)
                }
            }

            Section("语速与音量") {
                HStack {
                    Slider(value: Binding(get: { Double(page.rate) }, set: { page.setRate(Float($0)) }), in: 0.5...1.5)
                    Text(String(format: "%.2fx", page.rate)).font(.system(size: 11)).frame(width: 46)
                }
                HStack {
                    Slider(value: Binding(get: { Double(page.volume) }, set: { page.setVolume(Float($0)) }), in: 0...1)
                    Text(String(format: "%.0f%%", page.volume * 100)).font(.system(size: 11)).frame(width: 46)
                }
            }

            Section("每种语言锁定的音色（系统引擎）") {
                ForEach(SpeechPageModel.lockLanguages, id: \.self) { lang in
                    HStack(spacing: 8) {
                        Text(lang.displayName).frame(width: 76, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { page.locked[lang.rawValue] ?? "" },
                            set: { page.setLock($0, for: lang) })) {
                            Text("跟随系统默认").tag("")
                            ForEach(page.voices[lang.rawValue] ?? [], id: \.id) { voice in
                                Text(voice.name + " · " + voice.quality.displayName).tag(voice.id)
                            }
                        }
                        .labelsHidden()
                        Button("试听") { page.preview(lang) }
                            .font(.system(size: 11))
                    }
                }
                if page.isLoadingVoices {
                    ProgressView().controlSize(.small)
                }
            }

            Section("正在播放") {
                LabeledContent("状态", value: speech.isSpeaking ? "播放中：" + String((speech.speakingText ?? "").prefix(24)) : "空闲")
                if let error = speech.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(DSColor.danger)
                }
                HStack {
                    Button("停止") { speech.stop() }
                    Button("用当前引擎试听中文") { page.preview(.zhHans) }
                    Spacer(minLength: 0)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { page.engine = speech.engineKind }
    }
}

// MARK: - 划词

struct SelectionSettingsPage: View {
    @ObservedObject var model: SettingsModel
    let env: AppEnvironment
    @ObservedObject private var permissions: PermissionCenter

    init(model: SettingsModel, env: AppEnvironment) {
        self.model = model
        self.env = env
        self._permissions = ObservedObject(wrappedValue: env.permissions)
    }

    var body: some View {
        Form {
            Section("取词") {
                Toggle("选中文本后自动出现浮条", isOn: Binding(
                    get: { model.settings.selection.enabled },
                    set: { model.setSelectionEnabled($0) }))
                LabeledContent("辅助功能权限", value: permissions.accessibilityGranted ? "已授权" : "未授权（划词不可用）")
                Button("打开权限自检") { permissions.show() }
                Text("未授权时仍可用：⌥Space（读剪贴板）、菜单「翻译剪贴板」、菜单「手动输入…」。")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
            }
            Section("黑名单 App（bundle id，不弹浮条）") {
                ForEach(model.settings.selection.blocklist, id: \.self) { bundle in
                    HStack {
                        Text(bundle).font(.system(size: 12))
                        Spacer(minLength: 0)
                        Button("移除") { model.removeBlocklistEntry(bundle) }
                            .font(.system(size: 11))
                    }
                }
                HStack {
                    TextField("com.apple.Terminal", text: $model.blocklistDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        model.addBlocklistEntry(model.blocklistDraft)
                        model.blocklistDraft = ""
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 历史

struct HistorySettingsPage: View {
    @ObservedObject var model: SettingsModel
    let env: AppEnvironment

    var body: some View {
        Form {
            Section("条数") {
                Stepper(value: Binding(get: { model.settings.history.limit }, set: { model.setHistoryLimit($0) }), in: 50...20000, step: 50) {
                    Text("最多保留 \(model.settings.history.limit) 条")
                }
                Text("写入历史时按上限裁剪（trim）。库：~/Library/Application Support/TranslationReader/store.sqlite3")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
            }
            Section("操作") {
                HStack {
                    Button("打开历史窗口") { env.historyWindow.show() }
                    Button("导出 JSON…") { env.historyWindow.export() }
                    Button("清空历史") { env.historyWindow.clearAll() }
                    Spacer(minLength: 0)
                }
                if let error = env.historyError {
                    Text("历史库不可用：" + error).font(.system(size: 11)).foregroundStyle(DSColor.danger)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 关于

struct AboutSettingsPage: View {
    @ObservedObject var model: SettingsModel
    let env: AppEnvironment
    @ObservedObject private var permissions: PermissionCenter

    init(model: SettingsModel, env: AppEnvironment) {
        self.model = model
        self.env = env
        self._permissions = ObservedObject(wrappedValue: env.permissions)
    }

    var body: some View {
        Form {
            Section("版本") {
                HStack(spacing: 12) {
                    if let icon = Self.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 56, height: 56)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TranslationReader")
                            .font(.system(size: 13, weight: .semibold))
                        Text("全局翻译自动朗读 · 版本 " + AppDelegate.version)
                            .font(.system(size: 11))
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                LabeledContent("形态", value: "菜单栏常驻（LSUIElement=1）· macOS 14+")
            }
            Section("权限自检") {
                PermissionStatusRow(kind: .accessibility, granted: permissions.accessibilityGranted) {
                    permissions.openSettings(.accessibility)
                }
                PermissionStatusRow(kind: .screenRecording, granted: permissions.screenRecordingGranted) {
                    permissions.openSettings(.screenRecording)
                }
                Button("重新检测") { permissions.refresh() }
                Text("授权后无需重启；若用 ad-hoc 签名重建过 .app，TCC 授权会失效，需重新勾选。")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
            }
            Section("数据位置") {
                Text("历史库：~/Library/Application Support/TranslationReader/store.sqlite3")
                Text("sherpa 模型：~/Library/Application Support/TranslationReader/models/sherpa-onnx")
                Text("朗读缓存：~/Library/Caches/TranslationReader/tts")
                Button("复制 store 路径") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(Store.defaultDatabaseURL().path, forType: .string)
                }
            }
            .font(.system(size: 11))
        }
        .formStyle(.grouped)
    }

    /// 应用图标：优先从 bundle 里取 AppIcon.icns（裸二进制取证时可能为 nil，直接不显示）。
    static var appIcon: NSImage? {
        NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    }
}
