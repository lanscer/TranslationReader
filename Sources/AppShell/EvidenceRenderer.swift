import AppKit
import SwiftUI
import Contracts
import DesignSystem
import OverlayKit

/// 视觉证据离线渲染：--render-evidence 把卡片/设置页/历史页/权限页渲染成 PNG，
/// 不依赖屏幕录制权限（TCC 下无法用 screencapture 取证）。
@MainActor
enum EvidenceRenderer {
    static let outputDirectory = ".build-integration/evidence"

    static func run() {
        let env = AppEnvironment.shared
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outputDirectory)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var manifest: [String] = []

        // 1) 翻译卡：句子模式（译文 / 用法），深色
        let sentenceSession = TranslationSession(env: env)
        sentenceSession.applyEvidenceSample(
            source: "The quick brown fox jumps over the lazy dog. It is a classic pangram used for testing fonts.",
            translation: "敏捷的棕色狐狸跳过了懒狗。这是一个用于测试字体的经典全字母句。",
            detail: sampleSentenceDetail()
        )
        manifest.append(render(
            TranslationCardBody(session: sentenceSession, speech: env.speech),
            name: "card-sentence-dark",
            width: 420,
            appearance: .darkAqua
        ))

        // 2) 句子模式第二个 tab（出处）
        sentenceSession.applyEvidenceSample(
            source: "The quick brown fox jumps over the lazy dog.",
            translation: "敏捷的棕色狐狸跳过了懒狗。",
            detail: sampleSentenceDetail()
        )
        sentenceSession.selectTab(1)
        manifest.append(render(
            TranslationCardBody(session: sentenceSession, speech: env.speech),
            name: "card-sentence-origin-dark",
            width: 420,
            appearance: .darkAqua
        ))

        // 2b) Stage2 无细节：tab 区整块隐藏，译文只在正文出现一次
        let noDetailSession = TranslationSession(env: env)
        noDetailSession.applyEvidenceSample(
            source: "The quick brown fox jumps over the lazy dog.",
            translation: "敏捷的棕色狐狸跳过了懒狗。",
            detail: nil
        )
        manifest.append(render(
            TranslationCardBody(session: noDetailSession, speech: env.speech),
            name: "card-sentence-no-detail",
            width: 420,
            appearance: .darkAqua
        ))

        // 2c) 默认引擎：机器翻译（免密钥、只有译文，细节 tab 不存在）
        let machineSession = TranslationSession(env: env)
        machineSession.applyEvidenceSample(
            source: "Serendipity is the art of finding something valuable without looking for it.",
            translation: "机缘巧合，是那种不经意间发现珍贵事物的本事。",
            detail: nil,
            engine: .machine
        )
        manifest.append(render(
            TranslationCardBody(session: machineSession, speech: env.speech),
            name: "card-sentence-machine",
            width: 420,
            appearance: .darkAqua
        ))

        // 3) 单词模式：词条排版（简明）
        let wordSession = TranslationSession(env: env)
        wordSession.applyEvidenceSample(
            source: "serendipity",
            translation: "意外发现珍奇事物的能力；机缘凑巧",
            detail: sampleWordDetail(),
            kind: .selection
        )
        manifest.append(render(
            TranslationCardBody(session: wordSession, speech: env.speech),
            name: "card-word-dark",
            width: 420,
            appearance: .darkAqua
        ))

        // 4) 单词模式：例句 tab
        wordSession.selectTab(1)
        manifest.append(render(
            TranslationCardBody(session: wordSession, speech: env.speech),
            name: "card-word-examples-dark",
            width: 420,
            appearance: .darkAqua
        ))

        // 5) 浅色主题下的同一张卡（lead 要求两套色都在）
        manifest.append(render(
            TranslationCardBody(session: wordSession, speech: env.speech),
            name: "card-word-light",
            width: 420,
            appearance: .aqua
        ))

        // 6) 错误态（无 apiKey / 鉴权失败）—— 取证时把内存里的引擎切到 AI 且清空端点，
        //    保证失败路径确定、不真的发网络请求（不落盘，不影响用户设置）。
        env.settings.applyEvidenceEngine(.ai)
        env.settings.applyEvidenceBaseURL("")
        let errorSession = TranslationSession(env: env)
        errorSession.present(text: "The quick brown fox jumps over the lazy dog.", kind: .clipboard, editable: false)
        manifest.append(render(
            TranslationCardBody(session: errorSession, speech: env.speech),
            name: "card-error-no-api-key",
            width: 420,
            appearance: .darkAqua
        ))

        // 7) OCR 编辑态：识别结果 + 翻译结果同屏（离线灌样例，避免取证时真的发网络请求）
        let confirmSession = TranslationSession(env: env)
        confirmSession.applyEvidenceSample(
            source: "Translation should be fast.\n原文朗读优先，译文不发声。",
            translation: "翻译应该足够快。\n原文阅读优先，译文不发声。",
            detail: nil,
            kind: .ocr,
            confirm: true,
            engine: .machine
        )
        manifest.append(render(
            TranslationCardBody(session: confirmSession, speech: env.speech),
            name: "card-ocr-confirm",
            width: 420,
            appearance: .darkAqua
        ))

        // 8) 浮条（OverlayKit 提供的那个，必须还在用）
        let barModel = SelectionBarModel()
        barModel.present(Selection(text: "hello", bounds: .zero, appBundleID: "com.apple.Safari"))
        manifest.append(render(
            SelectionBarView(model: barModel),
            name: "selection-bar",
            width: nil,
            appearance: .darkAqua
        ))

        // 9) 设置 7 页（账号页先按新默认：机器翻译）
        let tabs = SettingsTabsModel()
        env.settings.applyEvidenceEngine(.machine)
        env.settings.applyEvidenceBaseURL("")
        env.settings.applyEvidenceLegacyKeychain(false)
        manifest.append(render(AccountSettingsPage(model: env.settings), name: "settings-account", width: 700, appearance: .aqua, fixedHeight: 640))

        // 9a-0) 账号页 · 检测到钥匙串旧条目时的迁移入口（仅展示，真实是否迁移由用户点按钮决定）
        // 这一组截图展示的是 AI 翻译的分支，切回 AI 引擎。
        env.settings.applyEvidenceEngine(.ai)
        env.settings.applyEvidenceLegacyKeychain(true)
        env.settings.keyStorageMessage = "检测到旧条目：点右侧按钮读取一次并删除，此后不再访问钥匙串。"
        manifest.append(render(AccountSettingsPage(model: env.settings), name: "settings-account-legacy-keychain", width: 700, appearance: .aqua, fixedHeight: 660))
        env.settings.applyEvidenceLegacyKeychain(false)
        env.settings.keyStorageMessage = nil

        // 9a) 账号页 · 拉取模型列表成功（真实 GET /models 抓到 5 个带前缀的模型名）
        env.settings.applyEvidenceBaseURL("http://127.0.0.1:8787/v1")
        env.settings.applyEvidenceModelNames(
            standard: "deepseek/deepseek-v4.1-flash",
            advanced: "deepseek/deepseek-v4.2-pro"
        )
        env.settings.applyEvidence(
            modelList: [
                "deepseek/deepseek-v4.1-flash",
                "deepseek/deepseek-v4.1-pro",
                "deepseek/deepseek-v4.2-pro",
                "meta-llama/llama-4-70b",
                "qwen/qwen3-max",
            ],
            diagnostic: nil,
            message: "拉到 5 个模型（35ms）"
        )
        manifest.append(render(AccountSettingsPage(model: env.settings), name: "settings-account-models", width: 700, appearance: .aqua, fixedHeight: 620))

        // 9b) 账号页 · 400 网关原文 + 可复制诊断行（桩端点真实回包）
        env.settings.applyEvidenceBaseURL("http://127.0.0.1:8787/badmodels")
        env.settings.applyEvidenceModelNames(
            standard: "deepseek-v4.1-flash",
            advanced: "deepseek-v4.2-pro"
        )
        env.settings.applyEvidence(
            modelList: [],
            diagnostic: "baseURL=http://127.0.0.1:8787/badmodels | 模型=deepseek-v4.1-flash | endpoint=http://127.0.0.1:8787/badmodels/models | HTTP 400 | 网关原文={\"error\":{\"message\":\"model deepseek-v4.1-flash not found, did you mean deepseek/deepseek-v4.1-flash?\",\"type\":\"invalid_request_error\",\"code\":\"model_not_found\"}}",
            message: "HTTP 400：「{\"error\":{\"message\":\"model deepseek-v4.1-flash not found, did you mean deepseek/deepseek-v4.1-flash?\"…"
        )
        manifest.append(render(AccountSettingsPage(model: env.settings), name: "settings-account-400", width: 700, appearance: .aqua, fixedHeight: 700))

        // 复原展示值，避免影响后续页面渲染
        env.settings.applyEvidenceBaseURL("")
        env.settings.applyEvidenceModelNames(standard: "", advanced: "")
        env.settings.applyEvidence(modelList: [], diagnostic: nil, message: nil)
        manifest.append(render(GeneralSettingsPage(model: env.settings), name: "settings-general", width: 700, appearance: .aqua, fixedHeight: 470))
        manifest.append(render(HotkeySettingsPage(model: env.settings, env: env), name: "settings-hotkey", width: 700, appearance: .aqua, fixedHeight: 470))
        manifest.append(render(SpeechSettingsPage(model: env.settings, page: SpeechPageModel(env: env), speech: env.speech), name: "settings-speech", width: 700, appearance: .aqua, fixedHeight: 620))
        manifest.append(render(SelectionSettingsPage(model: env.settings, env: env), name: "settings-selection", width: 700, appearance: .aqua, fixedHeight: 470))
        manifest.append(render(HistorySettingsPage(model: env.settings, env: env), name: "settings-history", width: 700, appearance: .aqua, fixedHeight: 470))
        manifest.append(render(AboutSettingsPage(model: env.settings, env: env), name: "settings-about", width: 700, appearance: .aqua, fixedHeight: 470))
        _ = tabs

        // 10) 历史页
        let historyController = env.historyWindow
        manifest.append(render(
            HistoryListView(model: HistoryListModel(env: env), controller: historyController),
            name: "history-window",
            width: 760,
            appearance: .aqua,
            fixedHeight: 520
        ))

        // 11) 权限自检页
        manifest.append(render(
            PermissionSelfCheckView(center: env.permissions),
            name: "permission-selfcheck",
            width: 470,
            appearance: .aqua,
            fixedHeight: 640
        ))

        // 12) 手动输入窗
        manifest.append(render(
            ManualInputView(model: ManualInputModel(env: env)),
            name: "manual-input",
            width: 480,
            appearance: .aqua,
            fixedHeight: 260
        ))

        // 13) toast
        manifest.append(render(
            ToastBanner(text: "朗读引擎已回落到系统引擎：本地引擎失败", isError: true),
            name: "toast",
            width: nil,
            appearance: .aqua
        ))

        let manifestText = manifest.joined(separator: "\n") + "\n"
        try? manifestText.write(to: root.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
        print(manifestText)
        fflush(stdout)
        exit(0)
    }

    @discardableResult
    static func render<V: View>(
        _ view: V,
        name: String,
        width: CGFloat?,
        appearance: NSAppearance.Name,
        fixedHeight: CGFloat? = nil
    ) -> String {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        if let width {
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: fixedHeight ?? 200)
        } else {
            hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        }
        hosting.layoutSubtreeIfNeeded()

        var size = hosting.fittingSize
        if let width { size.width = width }
        if let fixedHeight { size.height = fixedHeight }
        size.width = max(ceil(size.width), 80)
        size.height = max(ceil(size.height), 60)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return name + ": render-failed"
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return name + ": png-failed"
        }
        let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(name + ".png")
        do {
            try data.write(to: url)
        } catch {
            return name + ": write-failed " + String(describing: error)
        }
        let line = String(format: "%@.png  viewport=%.0fx%.0f  appearance=%@  bytes=%d",
                          name, size.width, size.height, appearance.rawValue, data.count)
        print("EVIDENCE|" + line)
        return line
    }

    // MARK: - 样例数据

    static func sampleWordDetail() -> TranslationDetail {
        TranslationDetail(
            sourceLang: .en,
            targetLang: .zhHans,
            translation: "意外发现珍奇事物的能力；机缘凑巧",
            mode: .word,
            senses: [
                .init(pos: "n.", defs: [
                    .init(def: "意外发现珍奇事物的能力；机缘凑巧", examples: [
                        .init(src: "Finding this café was pure serendipity.", tgt: "找到这家咖啡馆纯属机缘凑巧。"),
                        .init(src: "Science often advances by serendipity.", tgt: "科学常常因意外的发现而进步。"),
                    ]),
                    .init(def: "（事物）偶然被发现的特性", examples: []),
                ]),
                .init(pos: "adj.", defs: [
                    .init(def: "serendipitous：偶然的，意外发现的", examples: [
                        .init(src: "a serendipitous meeting", tgt: "一次偶然的相遇"),
                    ]),
                ]),
            ],
            synonyms: [.init(word: "chance", note: "偶然"), .init(word: "fluke", note: "侥幸")],
            usage: [.init(title: "serendipity vs. luck", body: "serendipity 强调「意外发现好东西」，luck 只是运气，不含发现义。")],
            notes: ["语域偏书面，口语里常用 lucky coincidence。"]
        )
    }

    static func sampleSentenceDetail() -> TranslationDetail {
        TranslationDetail(
            sourceLang: .en,
            targetLang: .zhHans,
            translation: "敏捷的棕色狐狸跳过了懒狗。这是一个用于测试字体的经典全字母句。",
            mode: .sentence,
            senses: [],
            synonyms: [],
            usage: [.init(title: "pangram", body: "全字母句，指包含全部 26 个字母的句子，常用于测试字体与输入法。")],
            notes: ["「quick」在此为古义「活的」，现代英语少见。"]
        )
    }
}
