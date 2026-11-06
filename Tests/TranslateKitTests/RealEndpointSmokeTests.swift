import Testing
import Foundation
import Contracts
import TranslateKit

enum SmokeEnvironment {
    static let baseURL = ProcessInfo.processInfo.environment["TR_SMOKE_BASE_URL"] ?? ""
    static let apiKey = ProcessInfo.processInfo.environment["TR_SMOKE_API_KEY"] ?? ""
    static let modelStandard = ProcessInfo.processInfo.environment["TR_SMOKE_MODEL_STANDARD"] ?? "gpt-4o-mini"
    static let modelAdvanced = ProcessInfo.processInfo.environment["TR_SMOKE_MODEL_ADVANCED"] ?? modelStandard
    static var isConfigured: Bool { !baseURL.isEmpty && !apiKey.isEmpty }
}

/// 冒烟通道：默认跳过；用 TR_SMOKE_BASE_URL / TR_SMOKE_API_KEY / TR_SMOKE_MODEL_STANDARD 开启。
/// 既可以打本地真实 HTTP 的 SSE 服务器，也可以打任意 OpenAI 兼容中转（脱敏输出，只打印时延与字数）。
@Suite("真实端点冒烟")
struct RealEndpointSmokeTests {
    @Test("Stage1 流式 + Stage2 细节跑通", .enabled(if: SmokeEnvironment.isConfigured))
    func smoke() async throws {
        var settings = AppSettings.Translate(baseURL: SmokeEnvironment.baseURL)
        settings.modelStandard = SmokeEnvironment.modelStandard
        settings.modelAdvanced = SmokeEnvironment.modelAdvanced

        let provider = OpenAITranslateProvider(settings: settings, apiKeyProvider: { SmokeEnvironment.apiKey })
        let clock = ContinuousClock()
        let start = clock.now
        var firstToken: Duration?
        var text = ""
        var detail: TranslationDetail?

        for try await event in provider.translate(makeTranslateRequest("Good morning")) {
            switch event {
            case .delta(let delta):
                if firstToken == nil { firstToken = start.duration(to: clock.now) }
                text += delta
            case .detail(let value):
                detail = value
            }
        }
        let total = start.duration(to: clock.now)
        let firstMs = Int((firstToken ?? .zero).timeInterval * 1000)
        let totalMs = Int(total.timeInterval * 1000)
        print("[smoke] endpoint=\(SmokeEnvironment.baseURL) first_token_ms=\(firstMs) total_ms=\(totalMs) chars=\(text.count) has_detail=\(detail != nil)")

        #expect(!text.isEmpty)
        #expect(firstToken != nil)
    }
}
