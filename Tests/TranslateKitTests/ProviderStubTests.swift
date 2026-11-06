import Testing
import Foundation
import Contracts
@testable import TranslateKit

@Suite("翻译 Provider（URLProtocol 桩）", .serialized)
struct ProviderStubTests {
    init() {
        StubServer.shared.reset()
    }

    @Test("200 流式：chunk 切断一行也能拼出完整译文")
    func streamHappyPath() async throws {
        let body = streamBody(["你好", "，世界", "！"])
        StubServer.shared.enqueue(StubPlan(status: 200, body: body, splitPoints: [5, 6, 18, 19, 33, 47], delayPerChunk: 0.004))
        let provider = makeStubProvider()
        let result = await collect(provider.translate(makeTranslateRequest("hello world")))

        #expect(result.error == nil)
        #expect(result.text == "你好，世界！")
        #expect(result.deltaCount == 3)
        #expect(StubServer.shared.requestCount == 1)
        #expect(StubServer.shared.recordedAuthorizations.first == "Bearer sk-test-SECRET-key-123")
        #expect(StubServer.shared.recordedURLs.first?.hasSuffix("/v1/chat/completions") == true)

        let bodyData = try #require(StubServer.shared.recordedBodies.first)
        let jsonObject = try JSONSerialization.jsonObject(with: bodyData)
        let payload = try #require(jsonObject as? [String: Any])
        #expect(payload["stream"] as? Bool == true)
        #expect(payload["model"] as? String == "gpt-4o-mini")
        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.last?["content"] as? String == "hello world")
        let bodyText = String(decoding: StubServer.shared.recordedBodies[0], as: UTF8.self)
        #expect(!bodyText.contains("sk-test-SECRET-key-123"))
    }

    @Test("畸形 chunk 与无冒号行被忽略，流继续")
    func malformedChunksIgnored() async {
        var body = "data: {this-is-not-json}\n\n"
        body += "garbage-line-without-colon\n\n"
        body += streamBody(["正常", "文本"])
        StubServer.shared.enqueue(StubPlan(status: 200, body: body))
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        #expect(result.error == nil)
        #expect(result.text == "正常文本")
    }

    @Test("401 → unauthorized，且不重试")
    func unauthorized() async {
        StubServer.shared.enqueue(StubPlan(status: 401, body: "{\"error\":{\"message\":\"bad key sk-test-SECRET-key-123\"}}"))
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        guard case .unauthorized(let host)? = result.error as? AppError else {
            Issue.record("期望 unauthorized，实际 \(String(describing: result.error))")
            return
        }
        #expect(host == "stub.local")
        #expect(StubServer.shared.requestCount == 1)
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(!message.contains("sk-test-SECRET-key-123"))
    }

    @Test("429 → 退避 800ms 后重试一次成功")
    func rateLimitRetry() async {
        StubServer.shared.enqueue(
            StubPlan(status: 429, body: "{}"),
            StubPlan(status: 200, body: streamBody(["限流后", "成功"]))
        )
        let policy = RequestPolicy(connectTimeout: 3, totalTimeout: 6, retryBackoff: 0.8, maxRetries: 1)
        let result = await collect(makeStubProvider(policy: policy).translate(makeTranslateRequest("hello")))
        #expect(result.error == nil)
        #expect(result.text == "限流后成功")
        #expect(StubServer.shared.requestCount == 2)
        #expect(result.elapsed >= 0.75)
    }

    @Test("5xx 重试一次后仍失败 → 透出 HTTP 状态与网关原文")
    func serverErrorExhausted() async {
        StubServer.shared.enqueue(StubPlan(status: 503, body: "{}"), StubPlan(status: 500, body: "{\"error\":{\"message\":\"upstream exploded\"}}"))
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(message.contains("HTTP 500"))
        #expect(message.contains("upstream exploded"))
        #expect(!message.contains("响应格式不合法"))
        #expect(StubServer.shared.requestCount == 2)
    }

    @Test("断连 → network 错误")
    func connectionDropped() async {
        StubServer.shared.enqueue(
            StubPlan(status: 200, body: streamBody(["半句"]), failAfterChunk: 0, error: URLError(.networkConnectionLost))
        )
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        guard case .network? = result.error as? AppError else {
            Issue.record("期望 network，实际 \(String(describing: result.error))")
            return
        }
    }

    @Test("响应头迟迟不来 → 连接超时")
    func connectTimeout() async {
        StubServer.shared.enqueue(StubPlan(neverRespond: true))
        let policy = RequestPolicy(connectTimeout: 0.2, totalTimeout: 5, retryBackoff: 0.05, maxRetries: 0)
        let result = await collect(makeStubProvider(policy: policy).translate(makeTranslateRequest("hello")))
        guard case .timeout(let seconds)? = result.error as? AppError else {
            Issue.record("期望 timeout，实际 \(String(describing: result.error))")
            return
        }
        #expect(seconds == 0.2)
        #expect(result.elapsed < 3)
    }

    @Test("慢流超出总时长 → 总超时")
    func totalTimeout() async {
        var frames: [String] = []
        for index in 0..<40 { frames.append("帧\(index)") }
        let body = streamBody(frames)
        let splits = Array(stride(from: 20, to: body.utf8.count - 1, by: 20))
        StubServer.shared.enqueue(StubPlan(status: 200, body: body, splitPoints: splits, delayPerChunk: 0.08))
        let policy = RequestPolicy(connectTimeout: 5, totalTimeout: 0.4, retryBackoff: 0.05, maxRetries: 0)
        let result = await collect(makeStubProvider(policy: policy).translate(makeTranslateRequest("hello")))
        guard case .timeout(let seconds)? = result.error as? AppError else {
            Issue.record("期望总超时，实际 \(String(describing: result.error))")
            return
        }
        #expect(seconds == 0.4)
        #expect(result.elapsed < 2)
    }

    @Test("单飞：3 个并发相同请求只发 1 次网络调用")
    func singleFlight() async {
        StubServer.shared.enqueue(StubPlan(status: 200, body: streamBody(["同", "一", "次"]), delayPerChunk: 0.06))
        let provider = makeStubProvider()
        let request = makeTranslateRequest("hello")

        async let first = collect(provider.translate(request))
        async let second = collect(provider.translate(request))
        async let third = collect(provider.translate(request))
        let results = await [first, second, third]

        #expect(StubServer.shared.requestCount == 1)
        #expect(results.allSatisfy { $0.text == "同一次" })
        #expect(results.allSatisfy { $0.error == nil })
    }

    @Test("缓存命中：第二次不再发请求且 ≤50ms")
    func cacheHit() async {
        StubServer.shared.enqueue(StubPlan(status: 200, body: streamBody(["缓存", "命中"])))
        let provider = makeStubProvider()
        let request = makeTranslateRequest("hello", target: .zhHans)

        let first = await collect(provider.translate(request))
        let second = await collect(provider.translate(request))

        #expect(first.text == "缓存命中")
        #expect(second.text == "缓存命中")
        #expect(StubServer.shared.requestCount == 1)
        #expect(second.elapsed < 0.05)
    }

    @Test("档位切换换 model")
    func tierSwitchesModel() async {
        StubServer.shared.enqueue(StubPlan(status: 200, body: streamBody(["标准"])), StubPlan(status: 200, body: streamBody(["高级"])))
        let provider = makeStubProvider()
        _ = await collect(provider.translate(makeTranslateRequest("hello", tier: .standard)))
        _ = await collect(provider.translate(makeTranslateRequest("hello", tier: .advanced)))

        let models: [String] = StubServer.shared.recordedBodies.compactMap { body in
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            return object["model"] as? String
        }
        #expect(models == ["gpt-4o-mini", "gpt-4o"])
    }

    @Test("Stage2 连续两次非法 JSON → 只降级细节，译文完整")
    func stage2Degrades() async {
        StubServer.shared.enqueue(
            StubPlan(status: 200, body: streamBody(["译文"])),
            StubPlan(status: 200, body: completionBody("不是 JSON")),
            StubPlan(status: 200, body: completionBody("还不是 JSON"))
        )
        let result = await collect(makeStubProvider(stage2: true).translate(makeTranslateRequest("hello")))
        #expect(result.error == nil)
        #expect(result.text == "译文")
        #expect(result.detail == nil)
        #expect(StubServer.shared.requestCount == 3)
    }

    @Test("Stage2 代码块围栏 JSON → 产出 detail 事件")
    func stage2Success() async {
        let detailJSON = "结果如下：\n" + "\u{0060}\u{0060}\u{0060}json\n"
            + "{\"translation\":\"译文\",\"senses\":[{\"pos\":\"n.\",\"defs\":[{\"def\":\"义项\",\"examples\":[{\"src\":\"a bird\",\"tgt\":\"一只鸟\"}]}]}],\"notes\":[\"备注\"]}"
            + "\n\u{0060}\u{0060}\u{0060}"
        StubServer.shared.enqueue(
            StubPlan(status: 200, body: streamBody(["译文"])),
            StubPlan(status: 200, body: completionBody(detailJSON))
        )
        let result = await collect(makeStubProvider(stage2: true).translate(makeTranslateRequest("bird", mode: .word)))
        #expect(result.error == nil)
        #expect(result.text == "译文")
        #expect(result.detail?.senses.first?.pos == "n.")
        #expect(result.detail?.senses.first?.defs.first?.def == "义项")
        #expect(result.detail?.senses.first?.defs.first?.examples.first?.tgt == "一只鸟")
        #expect(result.detail?.notes == ["备注"])
        #expect(StubServer.shared.requestCount == 2)
    }

    @Test("Stage2 遇 401 也只降级细节")
    func stage2UnauthorizedDegrades() async {
        StubServer.shared.enqueue(
            StubPlan(status: 200, body: streamBody(["译文"])),
            StubPlan(status: 401, body: "{}")
        )
        let result = await collect(makeStubProvider(stage2: true).translate(makeTranslateRequest("hello")))
        #expect(result.error == nil)
        #expect(result.text == "译文")
        #expect(result.detail == nil)
    }

    @Test("未配置 apiKey → missingAPIKey，且不发请求")
    func missingAPIKey() async {
        let result = await collect(makeStubProvider(apiKey: nil).translate(makeTranslateRequest("hello")))
        #expect((result.error as? AppError) == AppError.missingAPIKey)
        #expect(StubServer.shared.requestCount == 0)
    }

    @Test("服务端 error 文本里的 key 被脱敏")
    func errorMessageRedacted() async {
        var body = "data: " + String(decoding: jsonData(["error": ["message": "invalid api key sk-test-SECRET-key-123"]]), as: UTF8.self) + "\n\n"
        body += "data: [DONE]\n\n"
        StubServer.shared.enqueue(StubPlan(status: 200, body: body))
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(!message.isEmpty)
        #expect(!message.contains("sk-test-SECRET-key-123"))
        #expect(!String(describing: result.error).contains("sk-test-SECRET-key-123"))
    }

    @Test("脱敏工具本身")
    func redactionHelper() {
        let scrubbed = Redaction.scrub("key=sk-abcdef123456 and Bearer abcdef1234567890", secrets: ["sk-abcdef123456"])
        #expect(!scrubbed.contains("sk-abcdef123456"))
        #expect(scrubbed.contains(Redaction.placeholder))
    }

    // MARK: HTTP 错误体透出（生产缺陷回归）

    @Test("400 + 网关原文 → 文案带状态码与原文，且给模型前缀提示")
    func badRequestSurfacesGatewayMessage() async {
        StubServer.shared.enqueue(
            StubPlan(status: 400, body: "{\"error\":{\"message\":\"unknown model: x\"}}")
        )
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(message.contains("HTTP 400"))
        #expect(message.contains("unknown model: x"))
        #expect(message.contains("该端点模型名可能要求带厂商前缀"))
        #expect(message.contains("GET https://stub.local/v1/models"))
        #expect(StubServer.shared.requestCount == 1)
    }

    @Test("400 文案不含误导性的「响应格式不合法」前缀")
    func badRequestHasNoInvalidResponsePrefix() async {
        StubServer.shared.enqueue(StubPlan(status: 400, body: "{\"message\":\"model not found\"}"))
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(!message.contains("响应格式不合法"))
        #expect(message.contains("model not found"))
    }

    @Test("404 + 纯文本错误体 → 原文照出，非 model 关键字不加前缀提示")
    func notFoundPlainText() async {
        StubServer.shared.enqueue(StubPlan(status: 404, body: "gateway route missing"))
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(message.contains("HTTP 404"))
        #expect(message.contains("gateway route missing"))
        #expect(!message.contains("模型名可能要求带厂商前缀"))
    }

    @Test("错误体超长时截断到 200 字并带省略号")
    func longErrorBodyTruncated() async {
        let long = String(repeating: "很长的网关报错", count: 100)
        StubServer.shared.enqueue(StubPlan(status: 400, body: long))
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(message.contains("HTTP 400"))
        #expect(message.contains("…"))
        #expect(message.count < 300)
    }

    @Test("错误体里出现 apiKey 也会被抹掉")
    func errorBodyRedacted() async {
        StubServer.shared.enqueue(
            StubPlan(status: 400, body: "{\"error\":{\"message\":\"bad key sk-test-SECRET-key-123 for model x\"}}")
        )
        let result = await collect(makeStubProvider().translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(!message.contains("sk-test-SECRET-key-123"))
        #expect(message.contains("HTTP 400"))
        #expect(message.contains("bad key"))
    }

    // MARK: 端点归一化

    @Test("端点 URL 归一化：四种粘贴形态都收敛到同一 /chat/completions")
    func endpointNormalization() {
        let expected = "https://api.example.com/provider/v1/chat/completions"
        let inputs = [
            "https://api.example.com/provider/v1",
            "https://api.example.com/provider/v1/",
            "https://api.example.com/provider/v1/chat/completions",
            "https://api.example.com/provider/v1/chat/completions/",
        ]
        for input in inputs {
            #expect(OpenAITranslateProvider.completionsURL(baseURL: input)?.absoluteString == expected, "输入 \(input)")
            #expect(OpenAITranslateProvider.apiBaseURL(baseURL: input)?.absoluteString == "https://api.example.com/provider/v1", "输入 \(input)")
        }

        #expect(OpenAITranslateProvider.completionsURL(baseURL: "https://api.example.com")?.absoluteString == "https://api.example.com/chat/completions")
        #expect(OpenAITranslateProvider.apiBaseURL(baseURL: "https://api.example.com")?.absoluteString == "https://api.example.com")
        #expect(OpenAITranslateProvider.completionsURL(baseURL: "") == nil)
        #expect(OpenAITranslateProvider.completionsURL(baseURL: "   ") == nil)
        #expect(OpenAITranslateProvider.completionsURL(baseURL: "not a url") == nil)
        #expect(OpenAITranslateProvider.completionsURL(baseURL: "ftp://api.example.com") == nil)
    }

    @Test("已含完整端点的 baseURL 不会拼出 /chat/completions/chat/completions")
    func noDoublePath() async {
        StubServer.shared.enqueue(StubPlan(status: 200, body: streamBody(["好"])))
        let provider = makeStubProvider(baseURL: "https://stub.local/v1/chat/completions")
        let result = await collect(provider.translate(makeTranslateRequest("hello")))
        #expect(result.error == nil)
        #expect(result.text == "好")
        #expect(StubServer.shared.recordedURLs == ["https://stub.local/v1/chat/completions"])
    }

    // MARK: 机器翻译（默认引擎，免密钥）

    @Test("机器翻译：有道 POST 表单 + 译文解析")
    func machineYoudaoHappyPath() async {
        StubServer.shared.enqueue(StubPlan(status: 200, body: youdaoBody(["你好，世界。"])))
        let provider = makeStubMachineProvider(service: .youdao)
        let result = await collect(provider.translate(makeTranslateRequest("hello world", source: .auto)))

        #expect(result.error == nil)
        #expect(result.text == "你好，世界。")
        #expect(result.deltaCount == 1)
        #expect(StubServer.shared.requestCount == 1)
        #expect(StubServer.shared.recordedURLs.first == "https://aidemo.youdao.com/trans")
        let body = String(decoding: StubServer.shared.recordedBodies[0], as: UTF8.self)
        #expect(body.contains("q=hello%20world"))
        #expect(body.contains("from=auto"))
        #expect(body.contains("to=zh-CHS"))
    }

    @Test("机器翻译：有道 errorCode 非 0 时报错并带错误码")
    func machineYoudaoErrorCode() async {
        StubServer.shared.enqueue(StubPlan(status: 200, body: youdaoBody([], errorCode: "411")))
        let result = await collect(makeStubMachineProvider(service: .youdao).translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(result.error != nil)
        #expect(message.contains("机器翻译失败"))
        #expect(message.contains("411"))
    }

    @Test("机器翻译：MyMemory 的 langpair 与 HTML 实体解码")
    func machineMyMemory() async {
        StubServer.shared.enqueue(StubPlan(status: 200, body: myMemoryBody("你好 &amp; 世界")))
        let result = await collect(makeStubMachineProvider(service: .myMemory).translate(makeTranslateRequest("hello world")))
        #expect(result.error == nil)
        #expect(result.text == "你好 & 世界")
        let url = StubServer.shared.recordedURLs.first ?? ""
        #expect(url.contains("langpair="))
        #expect(url.contains("zh-CN"))
        #expect(url.contains("api.mymemory.translated.net"))
    }

    @Test("机器翻译：MyMemory 额度告警不算成功")
    func machineMyMemoryQuota() async {
        StubServer.shared.enqueue(StubPlan(
            status: 200,
            body: myMemoryBody("MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY")
        ))
        let result = await collect(makeStubMachineProvider(service: .myMemory).translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(result.error != nil)
        #expect(message.contains("MYMEMORY WARNING"))
    }

    @Test("机器翻译：谷歌嵌套数组解析")
    func machineGoogleParse() async {
        StubServer.shared.enqueue(StubPlan(status: 200, body: googleBody(["你好", "，世界"])))
        let result = await collect(makeStubMachineProvider(service: .google).translate(makeTranslateRequest("hello world", source: .auto)))
        #expect(result.error == nil)
        #expect(result.text == "你好，世界")
        let url = StubServer.shared.recordedURLs.first ?? ""
        #expect(url.contains("sl=auto"))
        #expect(url.contains("tl=zh-CN"))
    }

    @Test("机器翻译：自动链在有道 500 后回退到 MyMemory")
    func machineAutoFallback() async {
        StubServer.shared.enqueue(
            StubPlan(status: 500, body: "{\"message\":\"boom\"}"),
            StubPlan(status: 200, body: myMemoryBody("回退成功"))
        )
        let result = await collect(makeStubMachineProvider(service: .auto).translate(makeTranslateRequest("hello world")))
        #expect(result.error == nil)
        #expect(result.text == "回退成功")
        #expect(StubServer.shared.requestCount == 2)
        #expect(StubServer.shared.recordedURLs.first?.contains("aidemo.youdao.com") == true)
        #expect(StubServer.shared.recordedURLs.last?.contains("api.mymemory") == true)
    }

    @Test("机器翻译：三家全挂时错误文案点名每个服务")
    func machineAllFail() async {
        StubServer.shared.enqueue(
            StubPlan(status: 500, body: "{}"),
            StubPlan(status: 502, body: "{}"),
            StubPlan(status: 503, body: "{}")
        )
        let result = await collect(makeStubMachineProvider(service: .auto).translate(makeTranslateRequest("hello")))
        let message = (result.error as? AppError)?.userMessage ?? ""
        #expect(message.contains("有道"))
        #expect(message.contains("MyMemory"))
        #expect(message.contains("谷歌"))
        #expect(StubServer.shared.requestCount == 3)
    }

    @Test("机器翻译：命中缓存后不再发请求")
    func machineCacheHit() async {
        StubServer.shared.enqueue(StubPlan(status: 200, body: youdaoBody(["缓存译文"])))
        let provider = makeStubMachineProvider(service: .youdao)
        let first = await collect(provider.translate(makeTranslateRequest("hello world")))
        let second = await collect(provider.translate(makeTranslateRequest("hello world")))
        #expect(first.text == "缓存译文")
        #expect(second.text == "缓存译文")
        #expect(StubServer.shared.requestCount == 1)
    }

    @Test("机器翻译：超长文本按字节上限分块，多请求拼回全文")
    func machineChunking() async {
        let text = String(repeating: "This is a sentence. ", count: 40)
        let pieces = MachineTranslationText.chunks(text, maxBytes: 450)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.utf8.count <= 450 })
        #expect(pieces.joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })

        for index in pieces.indices {
            StubServer.shared.enqueue(StubPlan(status: 200, body: myMemoryBody("第\(index)段")))
        }
        let result = await collect(makeStubMachineProvider(service: .myMemory).translate(makeTranslateRequest(text)))
        #expect(result.error == nil)
        #expect(result.text.split(separator: "\n").count == pieces.count)
        #expect(StubServer.shared.requestCount == pieces.count)
    }

    @Test("机器翻译：空文本不发请求")
    func machineEmptyText() async {
        let result = await collect(makeStubMachineProvider(service: .youdao).translate(makeTranslateRequest("   ")))
        #expect(result.error != nil)
        #expect(StubServer.shared.requestCount == 0)
    }

    @Test("机器翻译：语言码映射与本地语种猜测")
    func machineLanguageCodes() {
        #expect(MachineTranslationLanguage.youdao(.zhHans) == "zh-CHS")
        #expect(MachineTranslationLanguage.youdao(.auto) == "auto")
        #expect(MachineTranslationLanguage.google(.zhHant) == "zh-TW")
        #expect(MachineTranslationLanguage.myMemory(.zhHans) == "zh-CN")
        #expect(MachineTranslationLanguage.detect("这是中文") == .zhHans)
        #expect(MachineTranslationLanguage.detect("こんにちは") == .ja)
        #expect(MachineTranslationLanguage.detect("안녕하세요") == .ko)
        #expect(MachineTranslationLanguage.detect("hello") == .en)
    }
}
