import Foundation
import Contracts
import DesignSystem
import HotkeyKit
import SelectionKit
import OverlayKit
import CaptureKitX
import OCRVision
import TranslateKit
import SpeechKit
import Store

/// T1 验收第 5 条的可编译证明：每个 Contracts 类型都在非 Contracts target 里被真实引用，
/// public 可见性一旦回退，本文件立刻编译失败。
enum ContractVisibility {
    static func probe() -> [String] {
        var seen: [String] = []

        seen.append(LangCode.en.rawValue)
        seen.append(LangCode.auto.displayName)
        seen.append(LanguagePair.default.target.rawValue)
        seen.append(LanguagePairPreset.all.first?.title ?? "")
        seen.append(AiTier.advanced.displayName)
        seen.append(TranslateMode.ocr.rawValue)

        let selection = Selection(text: "probe", bounds: .zero, appBundleID: "com.local.probe", isSecure: false)
        seen.append(selection.text)
        let reader: SelectionReading? = SelectionKit.makeReader()
        seen.append(reader == nil ? "no-reader" : "reader")

        let line = OcrLine(text: "probe", confidence: 1, box: .zero)
        let ocr = OcrResult(lines: [line], detectedLanguage: "en", elapsedMs: 0)
        seen.append(ocr.joinedText)
        seen.append(String(OCRVision.recognizeStub().lines.count))

        let request = TranslateRequest(text: "probe", pair: .default, tier: .standard, mode: .word)
        seen.append(request.text)
        let provider: TranslateProvider? = TranslateKit.makeProvider(settings: .init())
        seen.append(provider == nil ? "no-provider" : "provider")
        let deltaEvent: TranslateEvent = .delta("x")
        if case .delta(let delta) = deltaEvent { seen.append(delta) }
        let detailEvent: TranslateEvent = .detail(TranslationDetail())
        if case .detail(let detail) = detailEvent { seen.append(detail.mode.rawValue) }
        seen.append(TranslationDetail.Sense(pos: "n.").pos)
        seen.append(TranslationDetail.SenseDefinition(def: "鸟").def)
        seen.append(TranslationDetail.ExamplePair(src: "a", tgt: "b").tgt)
        seen.append(TranslationDetail.Synonym(word: "fowl").word)
        seen.append(TranslationDetail.UsageNote(title: "t", body: "b").body)

        seen.append(SpeechEngineKind.sherpa.displayName)
        seen.append(VoiceQuality.premium.displayName)
        seen.append(VoiceOption(id: "v", name: "Tingting", language: "zh-CN").name)
        let speechEvent: SpeechEvent = .boundary(offset: 3)
        if case .boundary(let offset) = speechEvent { seen.append(String(offset)) }
        seen.append(SpeechKit.makeEngine(kind: .system) == nil ? "no-engine" : "engine")

        seen.append(PermissionKind.screenRecording.settingsDeepLink)
        seen.append(AppError.unauthorized(host: "api.example.com").userMessage)
        seen.append(AppError.ttsFailed(reason: "x").userMessage)
        seen.append(AppError.permissionDenied(kind: .accessibility).requiresPermissionGuide ? "guide" : "no-guide")

        let settings = AppSettings.default
        seen.append(settings.general.autoSpeak ? "auto" : "manual")
        seen.append(settings.translate.model(for: .advanced))
        seen.append(settings.lang.defaultPair.source.rawValue)
        seen.append(settings.speech.engine.rawValue)
        seen.append(settings.selection.blocklist.first ?? "")
        seen.append(settings.hotkeys.capture)
        seen.append(String(settings.history.limit))

        seen.append(SourceKind.clipboard.rawValue)
        seen.append(HistoryEntry(id: "1", createdAt: 0, sourceText: "s").sourceText)

        seen.append(HotkeyKit.moduleName)
        seen.append(OverlayKit.moduleName)
        seen.append(String(describing: OverlayKit.cardSize.width))
        seen.append(CaptureKitX.moduleName)
        seen.append(Store.moduleName)
        seen.append(Store.keychainAccount)
        return seen
    }
}
