import Foundation
import Contracts

/// 非 2xx 响应：保留状态码与网关原文，交给上层格式化成用户可自查的文案。
struct HTTPStatusFailure: Error, Equatable {
    let status: Int
    let detail: String?

    var isAuth: Bool { status == 401 || status == 403 }
    var isRetryable: Bool { status == 429 || (500..<600).contains(status) }
}

public final class OpenAITranslateProvider: TranslateProvider, @unchecked Sendable {
    /// 网关错误体只取前 8KB，避免异常响应撑爆内存。
    static let maxErrorBodyBytes = 8 * 1024
    /// 错误文案里网关原文的上限（按字符）。
    static let detailCharacterLimit = 200

    public let settings: AppSettings.Translate
    public let policy: RequestPolicy
    public let cache: TranslateCache
    public let stage2Enabled: Bool

    private let apiKeyProvider: @Sendable () -> String?
    private let transport: HTTPTransport
    private let stage1Coalescer = Stage1Coalescer()
    private let stage2Coalescer = Stage2Coalescer()

    public init(
        settings: AppSettings.Translate,
        apiKeyProvider: @escaping @Sendable () -> String?,
        transport: HTTPTransport? = nil,
        policy: RequestPolicy? = nil,
        cache: TranslateCache = TranslateCache(),
        stage2Enabled: Bool = true
    ) {
        self.settings = settings
        self.apiKeyProvider = apiKeyProvider
        self.cache = cache
        self.stage2Enabled = stage2Enabled

        var resolved = policy ?? RequestPolicy()
        if policy == nil, settings.timeoutMs > 0 {
            resolved.totalTimeout = Double(settings.timeoutMs) / 1000
        }
        self.policy = resolved
        self.transport = transport ?? URLSessionTransport(policy: resolved)
    }

    // MARK: 端点归一化

    /// 等价于文档里的 {baseURL}：允许用户粘贴 /provider/v1、以斜杠结尾的 /v1/，
    /// 甚至完整端点 .../v1/chat/completions，统一裁成不含 /chat/completions 的基址。
    public static func apiBaseURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let suffix = "/chat/completions"
        while path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
            while path.hasSuffix("/") { path.removeLast() }
        }
        components.path = path
        return components.url
    }

    public static func completionsURL(baseURL: String) -> URL? {
        guard let base = apiBaseURL(baseURL: baseURL) else { return nil }
        return base.appendingPathComponent("chat/completions")
    }

    private var endpointHost: String? {
        Self.completionsURL(baseURL: settings.baseURL)?.host
    }

    // MARK: TranslateProvider

    public func translate(_ request: TranslateRequest) -> AsyncThrowingStream<TranslateEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { await self.run(request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: TranslateRequest,
        continuation: AsyncThrowingStream<TranslateEvent, Error>.Continuation
    ) async {
        do {
            if let hit = await cache.value(for: request, engine: .ai) {
                continuation.yield(.delta(hit.translation))
                if let detail = hit.detail { continuation.yield(.detail(detail)) }
                continuation.finish()
                return
            }

            guard let apiKey = currentAPIKey() else { throw AppError.missingAPIKey }

            let key = TranslateCache.key(for: request, engine: .ai)
            var fullText = ""
            let deltas = await stage1Coalescer.stream(for: key) { sink in
                try await self.requestStage1(request, apiKey: apiKey, sink: sink)
            }
            for try await delta in deltas {
                fullText += delta
                continuation.yield(.delta(delta))
            }
            let completedText = fullText
            await cache.store(request, engine: .ai, translation: completedText, detail: nil)

            if stage2Enabled, !completedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let detail = await stage2Coalescer.detail(key: key + "\u{1F}stage2") {
                    await self.requestStage2(request, apiKey: apiKey, stage1Text: completedText)
                }
                if let detail {
                    let value = detail.value
                    await cache.store(request, engine: .ai, translation: completedText, detail: value)
                    continuation.yield(.detail(value))
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: AppError.cancelled)
        } catch {
            continuation.finish(throwing: redact(error))
        }
    }

    // MARK: Stage1（stream=true）

    private func requestStage1(
        _ request: TranslateRequest,
        apiKey: String,
        sink: DeltaSink
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await performStage1(request, apiKey: apiKey, sink: sink)
                return
            } catch let failure as HTTPStatusFailure {
                if failure.isRetryable, attempt < policy.maxRetries {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(max(0, policy.retryBackoff) * 1_000_000_000))
                    continue
                }
                throw statusError(failure)
            }
        }
    }

    private func performStage1(
        _ request: TranslateRequest,
        apiKey: String,
        sink: DeltaSink
    ) async throws {
        let urlRequest = try makeRequest(request, stage: .stage1, apiKey: apiKey, stage1Text: nil)
        var parser = SSEParser()
        var head: HTTPResponseHead?
        var errorBody = Data()
        var sawDone = false

        do {
            for try await event in transport.stream(urlRequest) {
                switch event {
                case .head(let value):
                    head = value
                case .body(let data):
                    if let head, !(200..<300).contains(head.statusCode) {
                        if errorBody.count < Self.maxErrorBodyBytes { errorBody.append(data) }
                        continue
                    }
                    guard !sawDone else { continue }
                    for parsed in parser.feed(data) {
                        switch parsed {
                        case .done:
                            sawDone = true
                        case .data(let payload):
                            if let delta = try ChatResponseDecoder.streamDelta(from: payload) {
                                await sink.emit(delta)
                            }
                        }
                    }
                }
            }
        } catch let error as AppError {
            throw error
        } catch let failure as HTTPStatusFailure {
            throw failure
        } catch {
            throw mapTransportError(error)
        }

        guard let head else { throw AppError.invalidResponse(reason: "未收到响应头") }
        guard (200..<300).contains(head.statusCode) else {
            throw Self.failure(status: head.statusCode, body: errorBody)
        }

        if !sawDone {
            for parsed in parser.finish() {
                if case .data(let payload) = parsed,
                   let delta = try ChatResponseDecoder.streamDelta(from: payload) {
                    await sink.emit(delta)
                }
            }
        }
    }

    // MARK: Stage2（stream=false，失败只降级细节）

    private func requestStage2(
        _ request: TranslateRequest,
        apiKey: String,
        stage1Text: String
    ) async -> TranslationDetailBox? {
        for attempt in 0..<2 {
            do {
                let content = try await performStage2(
                    request,
                    apiKey: apiKey,
                    stage1Text: stage1Text,
                    strengthen: attempt > 0
                )
                if let detail = TranslationJSON.detail(
                    from: content,
                    fallbackTranslation: stage1Text,
                    request: request
                ) {
                    return TranslationDetailBox(value: detail)
                }
            } catch let failure as HTTPStatusFailure {
                if failure.isRetryable, attempt == 0 {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, policy.retryBackoff) * 1_000_000_000))
                    continue
                }
                return nil
            } catch {
                return nil // 断网 / 超时 / 401：细节降级，不动译文（文档 R6）
            }
        }
        return nil
    }

    private func performStage2(
        _ request: TranslateRequest,
        apiKey: String,
        stage1Text: String,
        strengthen: Bool
    ) async throws -> String {
        let urlRequest = try makeRequest(
            request,
            stage: .stage2(strengthen: strengthen),
            apiKey: apiKey,
            stage1Text: stage1Text
        )
        var body = Data()
        var head: HTTPResponseHead?
        do {
            for try await event in transport.stream(urlRequest) {
                switch event {
                case .head(let value):
                    head = value
                case .body(let data):
                    body.append(data)
                }
            }
        } catch let error as AppError {
            throw error
        } catch let failure as HTTPStatusFailure {
            throw failure
        } catch {
            throw mapTransportError(error)
        }

        guard let head else { throw AppError.invalidResponse(reason: "未收到响应头") }
        guard (200..<300).contains(head.statusCode) else {
            throw Self.failure(status: head.statusCode, body: body)
        }
        return try ChatResponseDecoder.completionsText(from: body)
    }

    // MARK: 请求构造

    enum Stage {
        case stage1
        case stage2(strengthen: Bool)
    }

    private func makeRequest(
        _ request: TranslateRequest,
        stage: Stage,
        apiKey: String,
        stage1Text: String?
    ) throws -> URLRequest {
        guard let url = Self.completionsURL(baseURL: settings.baseURL) else {
            throw AppError.invalidResponse(reason: "端点 URL 无效")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = policy.totalTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let system: String
        let user: String
        let stream: Bool
        switch stage {
        case .stage1:
            system = OpenAIPrompt.stage1System(request)
            user = OpenAIPrompt.stage1User(request)
            stream = true
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        case .stage2(let strengthen):
            system = OpenAIPrompt.stage2System(request, strengthen: strengthen)
            user = OpenAIPrompt.stage2User(request, stage1Translation: stage1Text ?? "")
            stream = false
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        urlRequest.httpBody = try ChatRequestBody.data(
            model: settings.model(for: request.tier),
            system: system,
            user: user,
            stream: stream
        )
        return urlRequest
    }

    // MARK: 错误体解析与文案

    /// 从网关错误体里取最像人话的那条：error.message / message / error / detail，兜底原文。
    static func errorDetail(from body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: body) {
            if let dictionary = object as? [String: Any] {
                if let error = dictionary["error"] as? [String: Any] {
                    if let message = error["message"] as? String, !message.isEmpty { return message }
                    if let code = error["code"] as? String, !code.isEmpty { return code }
                }
                if let message = dictionary["message"] as? String, !message.isEmpty { return message }
                if let error = dictionary["error"] as? String, !error.isEmpty { return error }
                if let detail = dictionary["detail"] as? String, !detail.isEmpty { return detail }
            }
            if let plain = object as? String, !plain.isEmpty { return plain }
        }
        return text
    }

    static func failure(status: Int, body: Data) -> HTTPStatusFailure {
        HTTPStatusFailure(status: status, detail: errorDetail(from: body))
    }

    /// 折叠空白并截断到 limit 个字符，避免一整页 HTML 灌进提示条。
    static func collapsed(_ text: String, limit: Int = detailCharacterLimit) -> String {
        let flattened = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    private func statusError(_ failure: HTTPStatusFailure) -> AppError {
        if failure.isAuth { return .unauthorized(host: endpointHost) }

        var message = "HTTP \(failure.status)"
        if let detail = failure.detail, !detail.isEmpty {
            message += " · " + Self.collapsed(redactText(detail))
        }
        if (failure.status == 400 || failure.status == 404),
           let detail = failure.detail,
           detail.lowercased().contains("model") {
            let base = Self.apiBaseURL(baseURL: settings.baseURL)?.absoluteString ?? settings.baseURL
            message += " · 该端点模型名可能要求带厂商前缀，可用 GET " + base + "/models 拉取可用 id"
        }
        return .unknown(message: message)
    }

    private func mapTransportError(_ error: Error) -> Error {
        if let transportError = error as? TransportError {
            switch transportError {
            case .timedOut(let seconds): return AppError.timeout(seconds: seconds)
            case .cancelled: return CancellationError()
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return AppError.timeout(seconds: policy.totalTimeout)
            case .cancelled: return CancellationError()
            default: return AppError.network(underlying: redactText(urlError.localizedDescription))
            }
        }
        return AppError.network(underlying: redactText(error.localizedDescription))
    }

    // MARK: Keychain 与脱敏

    private func currentAPIKey() -> String? {
        guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        return key
    }

    private func redactText(_ text: String) -> String {
        var secrets = [String]()
        if let key = currentAPIKey() { secrets.append(key) }
        return Redaction.scrub(text, secrets: secrets)
    }

    private func redact(_ error: Error) -> AppError {
        guard let appError = error as? AppError else {
            return .unknown(message: redactText(error.localizedDescription))
        }
        switch appError {
        case .network(let underlying):
            return .network(underlying: redactText(underlying))
        case .invalidResponse(let reason):
            return .invalidResponse(reason: redactText(reason))
        case .unknown(let message):
            return .unknown(message: redactText(message))
        case .ttsFailed(let reason):
            return .ttsFailed(reason: redactText(reason))
        default:
            return appError
        }
    }
}
