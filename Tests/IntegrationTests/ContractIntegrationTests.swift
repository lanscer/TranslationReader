import Testing
import Foundation
import Contracts
import DesignSystem
import OverlayKit
import HotkeyKit
import CaptureKitX

@Suite("跨模块契约集成")
struct ContractIntegrationTests {
    @Test("AppSettings 默认值可 JSON 往返")
    func settingsRoundTrip() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == AppSettings.default)
        #expect(decoded.speech.engine == .system)
        #expect(decoded.translate.model(for: .advanced) == "gpt-4o")
    }

    @Test("默认引擎是机器翻译（2026-11-06 起）")
    func defaultEngineIsMachine() {
        #expect(AppSettings.default.translate.engine == .machine)
        #expect(AppSettings.default.translate.machineService == .auto)
        #expect(AppSettings.default.translate.machineTimeoutMs == 8_000)
        #expect(TranslationEngineKind.allCases.count == 2)
        #expect(MachineTranslationService.auto.fallbackChain == [.youdao, .myMemory, .google])
    }

    @Test("旧版设置 JSON 缺 engine 等新字段时补齐默认值，且不丢其它设置")
    func legacySettingsDecoding() throws {
        var settings = AppSettings.default
        settings.hotkeys.capture = "opt+shift+s"
        settings.general.autoSpeak = false
        settings.translate.baseURL = "https://api.example.com/v1"

        let data = try JSONEncoder().encode(settings)
        let object = try JSONSerialization.jsonObject(with: data)
        var root = try #require(object as? [String: Any])
        var translate = try #require(root["translate"] as? [String: Any])
        translate.removeValue(forKey: "engine")
        translate.removeValue(forKey: "machineService")
        translate.removeValue(forKey: "machineTimeoutMs")
        root["translate"] = translate
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        #expect(decoded.translate.engine == .machine)
        #expect(decoded.translate.machineService == .auto)
        #expect(decoded.translate.machineTimeoutMs == 8_000)
        #expect(decoded.translate.baseURL == "https://api.example.com/v1")
        #expect(decoded.hotkeys.capture == "opt+shift+s")
        #expect(decoded.general.autoSpeak == false)
    }

    @Test("Stage2 JSON 缺字段时降级不抛错")
    func detailTolerantDecoding() throws {
        let json = "{\"source_lang\":\"en\",\"target_lang\":\"zh-Hans\",\"translation\":\"鸟\",\"mode\":\"word\"}"
        let detail = try JSONDecoder().decode(TranslationDetail.self, from: Data(json.utf8))
        #expect(detail.translation == "鸟")
        #expect(detail.senses.isEmpty)
        #expect(detail.mode == .word)
        #expect(detail.sourceLang == LangCode.en)
    }

    @Test("AppError 覆盖文档要求的六类错误")
    func errorMatrix() {
        let errors: [AppError] = [
            .unauthorized(host: "api.example.com"),
            .network(underlying: "offline"),
            .timeout(seconds: 25),
            .invalidResponse(reason: "bad json"),
            .ttsFailed(reason: "voice missing"),
            .permissionDenied(kind: .screenRecording),
        ]
        for error in errors {
            #expect(error.userMessage.isEmpty == false)
        }
        #expect(AppError.permissionDenied(kind: .accessibility).requiresPermissionGuide)
        #expect(PermissionKind.allCases.count == 2)
    }

    @Test("DesignSystem 与其余模块骨架可同时引用")
    func designSystemAndModules() {
        #expect(OverlayKit.cardSize.width == DSMetric.cardWidth)
        #expect(HotkeyKit.BindingPlaceholder.defaults.count == 3)
        #expect(CaptureKitX.permissionError() == .permissionDenied(kind: .screenRecording))
        #expect(DSColor.accent != DSColor.danger)
    }
}
