import AppKit
import Foundation
import Contracts
import CaptureKitX
import OCRVision
import SpeechKit
import TranslateKit

/// 验收测量模式（不进产品路径）：--selftest 跑一组可复现的数字，逐行打印「METRIC|键|值」。
@MainActor
enum SelfTest {
    static func handleCommandLine() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--render-evidence") {
            EvidenceRenderer.run()
            return true
        }
        if args.contains("--key-file-selftest") {
            runKeyFileSelftest()
            return true
        }
        if args.contains("--chain-smoke") {
            Task { @MainActor in
                await runChainSmoke()
                fflush(stdout)
                exit(0)
            }
            return true
        }
        if args.contains("--ocr-smoke") {
            Task { @MainActor in
                await runOCRSmoke()
                fflush(stdout)
                exit(0)
            }
            return true
        }
        if args.contains("--card-smoke") {
            Task { @MainActor in
                await runCardSmoke()
                fflush(stdout)
                exit(0)
            }
            return true
        }
        if args.contains("--mt-smoke") {
            Task { @MainActor in
                await runMachineTranslationSmoke()
                fflush(stdout)
                exit(0)
            }
            return true
        }
        if args.contains("--selftest") {
            Task { @MainActor in
                await run()
                fflush(stdout)
                exit(0)
            }
            return true
        }
        return false
    }

    private static func out(_ key: String, _ value: String) {
        print("METRIC|\(key)|\(value)")
        fflush(stdout)
    }

    // MARK: - 主流程

    static func run() async {
        let env = AppEnvironment.shared
        var peakRSS = 0
        let sampler = Task { @MainActor in
            for _ in 0..<4000 {
                let rss = Self.rssKB()
                if rss > peakRSS { peakRSS = rss }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        out("version", AppDelegate.version)
        out("pid", String(getpid()))
        out("accessibilityGranted", PermissionCenter.accessibilityGranted ? "1" : "0")
        out("screenRecordingGranted", PermissionCenter.screenRecordingGranted ? "1" : "0")
        out("sherpaInstalled", SpeechKit.isSherpaInstalled() ? "1" : "0")
        out("launchElapsedMs", String(LaunchClock.elapsedMs()))
        out("baseURL", env.settings.settings.translate.baseURL.isEmpty ? "(未配置)" : env.settings.settings.translate.baseURL)
        out("hasAPIKey", env.settings.hasAPIKey ? "1" : "0")
        out("historyCount", String(env.recentEntries(limit: 10000).count))

        // 1) idle RSS：先静置 1.5s 再采样
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        out("idleRSSMB", String(format: "%.1f", Double(Self.rssKB()) / 1024))
        peakRSS = max(peakRSS, Self.rssKB())

        // 2) OCR：预热 → 3 次识别（真实 Vision，不需要屏幕录制）
        let ocrStarted = DispatchTime.now()
        await OCRVision.prewarm()
        out("ocrPrewarmMs", String(Self.ms(since: ocrStarted)))
        var ocrTimes: [Int] = []
        for _ in 0..<3 {
            guard let image = Self.makeTextImage() else { continue }
            let t0 = DispatchTime.now()
            do {
                let result = try await OCRVision.recognize(image: image)
                let ms = Self.ms(since: t0)
                ocrTimes.append(ms)
                out("ocrRunMs", String(ms))
                out("ocrLineCount", String(result.lines.count))
                out("ocrJoinedText", result.lines.map(\.text).joined(separator: " / "))
            } catch {
                out("ocrError", String(describing: error))
            }
            if let last = ocrTimes.last { peakRSS = max(peakRSS, Self.rssKB()) ; _ = last }
        }
        if !ocrTimes.isEmpty {
            let sorted = ocrTimes.sorted()
            out("ocrMedianMs", String(sorted[sorted.count / 2]))
        }

        // 3) 首字延迟：系统引擎 3 次
        for index in 1...3 {
            let measured = await measure(kind: .system, text: "这一句用来测量系统语音引擎的首字延迟。", lang: "zh-CN", timeout: 6)
            out("systemSpeak\(index)", measured)
            peakRSS = max(peakRSS, Self.rssKB())
        }

        // 4) 首字延迟：sherpa 3 次（首次为冷启）
        if SpeechKit.isSherpaInstalled() {
            for index in 1...3 {
                let measured = await measure(kind: .sherpa, text: "这一句用来测量本地引擎的首字延迟。", lang: "zh-CN", timeout: 20)
                out("sherpaSpeak\(index)", measured)
                peakRSS = max(peakRSS, Self.rssKB())
            }
        } else {
            out("sherpaSpeak1", "未安装 models/sherpa-onnx")
        }

        // 5) 引擎切换：系统 → sherpa → 系统，各朗读一句
        var fallbackCount = 0
        let service = SpeechService(store: InMemorySpeechSettingsStore()) { _ in fallbackCount += 1 }
        for kind in [SpeechEngineKind.sherpa, .system] {
            let t0 = DispatchTime.now()
            service.setEngine(kind)
            var events: [String] = []
            let collect = Task { @MainActor in
                for await event in service.speak("引擎已切换，这是切换后的试读。", lang: "zh-CN") {
                    switch event {
                    case .started: events.append("started@\(Self.ms(since: t0))ms")
                    case .finished: events.append("finished@\(Self.ms(since: t0))ms")
                    case .failed(let error): events.append("failed:\(error.userMessage)")
                    case .boundary: break
                    }
                }
            }
            try? await Task.sleep(nanoseconds: kind == .sherpa ? 12_000_000_000 : 6_000_000_000)
            service.stop()
            collect.cancel()
            out("switchTo_\(kind.rawValue)", events.joined(separator: ","))
        }
        out("fallbackNoticeCount", String(fallbackCount))

        // 6) 八种语言：系统引擎各朗读一句（看事件与音色）
        let languages: [(LangCode, String)] = [
            (.zhHans, "这是简体中文的原文朗读。"),
            (.en, "This is a sentence read aloud in English."),
            (.ja, "これは日本語の原文朗読です。"),
            (.ko, "이것은 한국어 원문 낭독입니다."),
            (.fr, "Ceci est une phrase lue en français."),
            (.de, "Dies ist ein auf Deutsch vorgelesener Satz."),
            (.ru, "Это предложение читается по-русски."),
            (.pt, "Esta é uma frase lida em português."),
            (.es, "Esta es una frase leída en español."),
        ]
        for (lang, text) in languages {
            let voices = await SpeechKit.makeEngine(kind: .system)?.voices(for: lang.rawValue) ?? []
            let voice = voices.first
            let measured = await measure(kind: .system, text: text, lang: lang.rawValue, timeout: 8)
            out("lang_\(lang.rawValue)", (voice.map { "voice=\($0.name)/\($0.language)/\($0.quality.displayName)" } ?? "voice=none") + " " + measured)
            peakRSS = max(peakRSS, Self.rssKB())
        }

        // 7) 翻译首 token：机器翻译（默认）直接跑；AI 需要端点 + key。
        out("translateEngine", env.settings.settings.translate.engine.rawValue)
        if let provider = env.makeProvider() {
            let t0 = DispatchTime.now()
            do {
                var first: String?
                for try await event in provider.translate(TranslateRequest(
                    text: "The quick brown fox jumps over the lazy dog.",
                    pair: LanguagePair(source: .en, target: .zhHans),
                    tier: .standard,
                    mode: .sentence
                )) {
                    if case .delta(let delta) = event, !delta.isEmpty {
                        out("translateFirstTokenMs", String(Self.ms(since: t0)))
                        first = delta
                        break
                    }
                }
                out("translateFirstTokenPreview", first ?? "(空)")
            } catch {
                out("translateError", (error as? AppError)?.userMessage ?? String(describing: error))
            }
        } else {
            out("translateFirstTokenMs", "未测（AI 引擎但 baseURL 为空；机器翻译不会走到这里）")
        }

        // 8) 卡片落位耗时（真实 NSPanel，不含用户操作）
        let cardStart = DispatchTime.now()
        let panelSession = TranslationSession(env: env)
        panelSession.applyEvidenceSample(source: "The quick brown fox.", translation: "敏捷的棕色狐狸。", detail: nil)
        let panel = TranslationCardPanel(session: panelSession, speech: env.speech)
        _ = panel.present(anchor: CGRect(x: 400, y: 400, width: 120, height: 20))
        out("cardPresentMs", String(Self.ms(since: cardStart)))
        out("cardFrame", String(format: "x=%.0f y=%.0f w=%.0f h=%.0f", panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height))
        panel.orderOut(nil)

        // 9) 峰值 RSS
        sampler.cancel()
        peakRSS = max(peakRSS, Self.rssKB())
        out("peakRSSMB", String(format: "%.1f", Double(peakRSS) / 1024))
        out("done", "1")
    }

    // MARK: - 截图 OCR 冒烟（--ocr-smoke）

    /// 真实走「全屏 ScreenCaptureKit → Vision OCR（15s 硬超时）」，
    /// 用来复现「截图后流程卡死」并量化各段耗时。不需要辅助功能权限。
    static func runOCRSmoke() async {
        guard let screen = NSScreen.main,
              let displayID = ScreenGeometry.displayID(of: screen) else {
            print("OCR|error=no-screen")
            return
        }
        let selection = CaptureKitX.RegionSelection(
            displayID: displayID,
            rect: CGRect(origin: .zero, size: screen.frame.size),
            scale: ScreenGeometry.pixelScale(of: displayID),
            isFullScreen: true
        )
        let env = ProcessInfo.processInfo.environment
        let timeout = Double(env["TR_OCR_TIMEOUT_S"] ?? "") ?? 20
        let prewarmStart = DispatchTime.now()
        await OCRVision.prewarm()
        print("OCR|prewarmMs=\(ms(since: prewarmStart))")
        let started = DispatchTime.now()
        do {
            let captured = try await ScreenCaptureService.capture(selection, hiding: [], settleMilliseconds: 60)
            let captureMs = ms(since: started)
            print("OCR|display=\(ScreenGeometry.describe(displayID))|captureMs=\(captureMs)")
            let ocr = try await OCRVision.recognizeWithTimeout(image: captured.image, timeout: timeout)
            print("OCR|captureMs=\(captureMs)|ocrMs=\(ocr.elapsedMs)|lines=\(ocr.lines.count)"
                  + "|totalMs=\(ms(since: started))|lang=\(ocr.detectedLanguage ?? "-")")
        } catch {
            let message = (error as? AppError)?.userMessage ?? String(describing: error)
            print("OCR|error=\(message)|afterMs=\(ms(since: started))")
        }
    }

    // MARK: - 卡片全链路冒烟（--card-smoke）

    /// 真实走「present → 当前默认引擎翻译 → 卡片状态」，验证免密钥出译文这条主路径。
    /// 不需要屏幕录制 / 辅助功能；冒烟期间立刻停朗读，避免出声。
    static func runCardSmoke() async {
        let env = AppEnvironment.shared
        let text = "The quick brown fox jumps over the lazy dog."
        // TR_CARD_EDITABLE=1 走 OCR 确认态：验证「截图卡片一出现就自动朗读」，再确认翻译。
        let editable = ProcessInfo.processInfo.environment["TR_CARD_EDITABLE"] == "1"
        let started = DispatchTime.now()
        env.card.present(
            text: text,
            kind: editable ? .ocr : .clipboard,
            anchor: CGRect(x: 200, y: 200, width: 1, height: 1),
            editable: editable
        )
        let spokeOnOpen = env.speech.isSpeaking
        let spokenText = env.speech.speakingText
        env.speech.stop()
        let session = env.card.session
        if editable {
            // 模拟用户改错字后重新翻译：TR_CARD_EDIT_TEXT="改过的文本"
            if let edited = ProcessInfo.processInfo.environment["TR_CARD_EDIT_TEXT"] {
                session.editableText = edited
            }
            session.confirmOCR()
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !session.translationText.isEmpty || session.phase == .failed { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        env.speech.stop()
        // 取证用：TR_CARD_HOLD_MS=4000 让卡片停留在屏幕上，供 screencapture 抓真实渲染。
        if let hold = Double(ProcessInfo.processInfo.environment["TR_CARD_HOLD_MS"] ?? ""), hold > 0 {
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000))
        }
        print("CARD|engine=\(session.engine.rawValue)|phase=\(session.phase.rawValue)|ms=\(ms(since: started))"
              + "|len=\(session.translationText.count)|tabs=\(session.tabs.count)"
              + "|spokeOnOpen=\(spokeOnOpen ? 1 : 0)|spoken=\(spokenText ?? "-")"
              + "|error=\(session.errorText ?? "-")|text=\(session.translationText)")
        env.card.hide()
    }

    // MARK: - 机器翻译在线冒烟（--mt-smoke）

    /// 按当前设置真跑一次机器翻译：中→英、英→中各一句，打印耗时与译文。
    /// 不需要任何 API Key，用来验证「默认引擎开箱即用」这条产品口径。
    static func runMachineTranslationSmoke() async {
        let env = AppEnvironment.shared
        let settings = env.settings.settings.translate
        let engine = settings.engine
        print("MT|engine=\(engine.rawValue)|service=\(settings.machineService.rawValue)")
        guard let provider = TranslateKit.makeProvider(settings: settings, engine: engine) else {
            print("MT|provider=nil")
            return
        }
        let samples: [(String, String, LanguagePair)] = [
            ("en2zh", "The quick brown fox jumps over the lazy dog.", LanguagePair(source: .auto, target: .zhHans)),
            ("zh2en", "今天天气不错，适合出门散步。", LanguagePair(source: .auto, target: .en)),
        ]
        for (label, text, pair) in samples {
            let started = DispatchTime.now()
            do {
                var translation = ""
                for try await event in provider.translate(TranslateRequest(text: text, pair: pair, mode: .sentence)) {
                    if case .delta(let delta) = event { translation += delta }
                }
                print("MT|\(label)|ms=\(ms(since: started))|len=\(translation.count)|text=\(translation)")
            } catch {
                let message = (error as? AppError)?.userMessage ?? String(describing: error)
                print("MT|\(label)|error=\(message)")
            }
        }
    }

    // MARK: - 工具

    private static func measure(kind: SpeechEngineKind, text: String, lang: String, timeout: TimeInterval) async -> String {
        guard let engine = SpeechKit.makeEngine(kind: kind) else { return "engine=nil" }
        let t0 = DispatchTime.now()
        var events: [String] = []
        let voice = VoiceOption(id: "", name: "", language: SpeechLanguage.bcp47(lang), engine: kind)
        let collect = Task { @MainActor in
            for await event in engine.speak(text, voice: voice, rate: 1.0, volume: 0.9) {
                switch event {
                case .started: events.append("started@\(Self.ms(since: t0))ms")
                case .finished: events.append("finished@\(Self.ms(since: t0))ms")
                case .failed(let error): events.append("failed:\(error.userMessage)")
                case .boundary: break
                }
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        engine.stop()
        collect.cancel()
        return events.isEmpty ? "no-events(\(Int(timeout))s)" : events.joined(separator: ",")
    }

    static func rssKB() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(getpid())]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(text) ?? 0
    }

    private static func makeTextImage(width: Int = 900, height: Int = 260) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        ("Translation should be fast.\n原文朗读优先，译文不发声。\nQuick brown fox 2026." as NSString)
            .draw(in: CGRect(x: 40, y: 60, width: CGFloat(width - 80), height: CGFloat(height - 100)), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    // MARK: - 密钥文件存储自检（只写临时目录，不碰用户真实密钥）

    private static func runKeyFileSelftest() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-key-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let sample = "sk-selftest-0123456789abcdef"
        do {
            try APIKeyFileStore.write(sample, to: temp)
            let readBack = APIKeyFileStore.read(from: temp)
            let filePath = temp.appendingPathComponent("apikey.bin")
            let fileAttrs = try FileManager.default.attributesOfItem(atPath: filePath.path)
            let filePerms = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let dirAttrs = try FileManager.default.attributesOfItem(atPath: temp.path)
            let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let raw = (try? Data(contentsOf: filePath)) ?? Data()
            let rawText = String(decoding: raw, as: UTF8.self)
            let roundtrip = readBack == sample ? "ok" : "fail"
            let plaintext = rawText.contains(sample) ? "yes" : "no"
            print("KEYSELFTEST|roundtrip=" + roundtrip
                  + "|filePerms=" + String(filePerms, radix: 8)
                  + "|dirPerms=" + String(dirPerms, radix: 8)
                  + "|plaintextInFile=" + plaintext
                  + "|size=" + String(raw.count))
            APIKeyFileStore.remove(from: temp)
            let removed = FileManager.default.fileExists(atPath: filePath.path) ? "no" : "yes"
            print("KEYSELFTEST|removed=" + removed)
        } catch {
            print("KEYSELFTEST|error=" + String(describing: error))
        }
        fflush(stdout)
        exit(0)
    }

    // MARK: - 双链路冒烟（本地 OpenAI 兼容桩端点，见 .build-integration/stub-openai.js）

    /// 用 TR_SMOKE_BASE_URL / TR_SMOKE_API_KEY 指针，把「取文 → 翻译（真 HTTP+SSE）→ 朗读 → 历史 → 卡片」
    /// 与「截图 → OCR → 确认态 → 翻译」两条链路各跑一遍，并把真实结果渲染成 PNG。
    static func runChainSmoke() async {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = environment["TR_SMOKE_BASE_URL"] ?? ""
        let apiKey = environment["TR_SMOKE_API_KEY"] ?? ""
        guard !baseURL.isEmpty else {
            print("CHAIN|skipped|未设置 TR_SMOKE_BASE_URL（用桩端点：node .build-integration/stub-openai.js）")
            fflush(stdout)
            return
        }
        let env = AppEnvironment.shared
        var translateSettings = AppSettings.Translate()
        // 冒烟链路固定走 AI 的 OpenAI 兼容桩端点，不受默认引擎影响。
        translateSettings.engine = .ai
        translateSettings.baseURL = baseURL
        translateSettings.modelStandard = environment["TR_SMOKE_MODEL_STANDARD"] ?? "stub-model"
        translateSettings.timeoutMs = 20_000
        guard let provider = TranslateKit.makeProvider(settings: translateSettings, apiKey: apiKey.isEmpty ? "sk-stub" : apiKey) else {
            print("CHAIN|abort|baseURL 无法解析")
            return
        }
        print("CHAIN|endpoint|\(baseURL)")
        fflush(stdout)

        // 链路 ①：剪贴板/手动输入 → 朗读 + 译文 + 词条细节
        let chainOneText = "Serendipity is the art of finding something valuable without looking for it."
        let t0 = DispatchTime.now()
        var firstTokenMs: Int?
        var translation = ""
        var detail: TranslationDetail?
        do {
            for try await event in provider.translate(TranslateRequest(
                text: chainOneText,
                pair: LanguagePair(source: .en, target: .zhHans),
                tier: .standard,
                mode: .sentence
            )) {
                switch event {
                case .delta(let delta):
                    if firstTokenMs == nil, !delta.isEmpty { firstTokenMs = Self.ms(since: t0) }
                    translation += delta
                case .detail(let value):
                    detail = value
                }
            }
        } catch {
            print("CHAIN|chain1|failed|\((error as? AppError)?.userMessage ?? String(describing: error))")
            fflush(stdout)
            return
        }
        let totalMs = Self.ms(since: t0)
        print("CHAIN|chain1|firstTokenMs=\(firstTokenMs ?? -1)|totalMs=\(totalMs)|translationLen=\(translation.count)|hasDetail=\(detail == nil ? 0 : 1)")
        fflush(stdout)

        // 朗读原文（系统引擎），并记录首字
        let speak = await measure(kind: .system, text: chainOneText, lang: "en-US", timeout: 6)
        print("CHAIN|chain1|speak|\(speak)")
        fflush(stdout)

        // 渲染真实结果的卡片
        let session = TranslationSession(env: env)
        session.applyEvidenceSample(source: chainOneText, translation: translation, detail: detail, kind: .clipboard)
        EvidenceRenderer.render(
            TranslationCardBody(session: session, speech: env.speech),
            name: "chain1-clipboard-real",
            width: 420,
            appearance: .darkAqua
        )

        // 写一条真实历史（SQLite）
        let entry = HistoryEntry(
            id: UUID().uuidString,
            createdAt: Int(Date().timeIntervalSince1970),
            sourceText: chainOneText,
            sourceLang: .en,
            targetLang: .zhHans,
            translation: translation,
            detail: detail,
            tier: .standard,
            model: "stub-model",
            sourceKind: .clipboard,
            appBundleID: nil,
            ocrImagePath: nil,
            error: nil
        )
        env.insertHistory(entry)
        print("CHAIN|chain1|historyCount=\(env.recentEntries(limit: 100).count)")
        fflush(stdout)

        // 模型列表：成功（200）与失败（400 网关原文）两条都要真跑一遍
        switch await ModelCatalogClient.fetch(baseURL: baseURL, apiKey: apiKey.isEmpty ? "sk-stub" : apiKey) {
        case .success(let catalog):
            print("CHAIN|models|ok|count=\(catalog.models.count)|first=\(catalog.models.first ?? "-")|ms=\(catalog.elapsedMs)")
        case .failure(let error):
            print("CHAIN|models|fail|\(error.userMessage)")
        }
        let badBase = baseURL.replacingOccurrences(of: "/v1/models", with: "").replacingOccurrences(of: "/v1", with: "") + "/badmodels"
        switch await ModelCatalogClient.fetch(baseURL: badBase, apiKey: apiKey) {
        case .success(let catalog):
            print("CHAIN|models400|unexpected-success|\(catalog.models.count)")
        case .failure(let error):
            print("CHAIN|models400|diag|" + error.diagnostic(baseURL: badBase, modelName: "deepseek-v4.1-flash"))
        }
        fflush(stdout)

        // 链路 ②：截图 → OCR → 确认态 → 翻译
        guard let image = makeTextImage() else {
            print("CHAIN|chain2|failed|测试图生成失败")
            return
        }
        // 真实 App 在启动时就预热了 Vision（AppDelegate.bootstrap），这里显式对齐一次，
        // 然后连跑两次：第一次记冷启，第二次记热态。
        await OCRVision.prewarm()
        do {
            _ = try? await OCRVision.recognize(image: image)
        }
        let ocrStart = DispatchTime.now()
        do {
            let result = try await OCRVision.recognize(image: image)
            let ocrMs = Self.ms(since: ocrStart)
            let text = result.lines.map(\.text).joined(separator: "\n")
            print("CHAIN|chain2|ocrMs=\(ocrMs)|lines=\(result.lines.count)|text=\(text.replacingOccurrences(of: "\n", with: " / "))")
            fflush(stdout)

            let confirmSession = TranslationSession(env: env)
            confirmSession.present(text: text, kind: .ocr, editable: true)
            EvidenceRenderer.render(
                TranslationCardBody(session: confirmSession, speech: env.speech),
                name: "chain2-ocr-confirm-real",
                width: 420,
                appearance: .darkAqua
            )

            let t1 = DispatchTime.now()
            var ocrTranslation = ""
            var ocrDetail: TranslationDetail?
            for try await event in provider.translate(TranslateRequest(
                text: text,
                pair: LanguagePair(source: .auto, target: .zhHans),
                tier: .standard,
                mode: .ocr
            )) {
                switch event {
                case .delta(let delta): ocrTranslation += delta
                case .detail(let value): ocrDetail = value
                }
            }
            print("CHAIN|chain2|translateMs=\(Self.ms(since: t1))|translationLen=\(ocrTranslation.count)|hasDetail=\(ocrDetail == nil ? 0 : 1)")
            fflush(stdout)

            let resultSession = TranslationSession(env: env)
            resultSession.applyEvidenceSample(source: text, translation: ocrTranslation, detail: ocrDetail, kind: .ocr)
            EvidenceRenderer.render(
                TranslationCardBody(session: resultSession, speech: env.speech),
                name: "chain2-ocr-result-real",
                width: 420,
                appearance: .darkAqua
            )
        } catch {
            print("CHAIN|chain2|failed|\(error)")
        }
        print("CHAIN|done|1")
        fflush(stdout)
    }
}
