import Foundation
import Contracts
import TranslateKit

// MARK: - URLProtocol 桩（文档 §10：覆盖 200 / 401 / 429 / 断连 / 慢流）

struct StubPlan: Sendable {
    var status: Int = 200
    var body: String = ""
    var splitPoints: [Int] = []
    var delayPerChunk: TimeInterval = 0
    var failAfterChunk: Int? = nil
    var error: URLError = URLError(.networkConnectionLost)
    var neverRespond: Bool = false
    var headers: [String: String] = ["Content-Type": "text/event-stream"]

    func chunks() -> [Data] {
        let bytes = Array(body.utf8)
        guard !splitPoints.isEmpty else { return [Data(bytes)] }
        var bounds = [0]
        bounds.append(contentsOf: splitPoints.filter { $0 > 0 && $0 < bytes.count }.sorted())
        bounds.append(bytes.count)
        var result: [Data] = []
        for index in 0..<(bounds.count - 1) where bounds[index] < bounds[index + 1] {
            result.append(Data(bytes[bounds[index]..<bounds[index + 1]]))
        }
        return result
    }
}

final class StubServer: @unchecked Sendable {
    static let shared = StubServer()

    private let lock = NSLock()
    private var plans: [StubPlan] = []
    private var recorded: [(url: String, authorization: String?, body: Data)] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        plans = []
        recorded = []
    }

    func enqueue(_ plans: StubPlan...) {
        lock.lock(); defer { lock.unlock() }
        self.plans.append(contentsOf: plans)
    }

    func next(for request: URLRequest) -> StubPlan {
        lock.lock(); defer { lock.unlock() }
        recorded.append((request.url?.absoluteString ?? "", request.value(forHTTPHeaderField: "Authorization"), Self.body(of: request)))
        if plans.isEmpty { return StubPlan() }
        return plans.removeFirst()
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recorded.count
    }

    var recordedBodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map { $0.body }
    }

    var recordedAuthorizations: [String?] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map { $0.authorization }
    }

    var recordedURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map { $0.url }
    }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class StubURLProtocol: URLProtocol {
    private let queue = DispatchQueue(label: "translatekit.stub.protocol")
    private var cancelled = false
    private var plan = StubPlan()
    private var chunks: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        plan = StubServer.shared.next(for: request)
        chunks = plan.chunks()
        guard !plan.neverRespond else { return }
        queue.async { [weak self] in self?.sendHead() }
    }

    override func stopLoading() {
        queue.async { self.cancelled = true }
    }

    private func sendHead() {
        guard !cancelled else { return }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: plan.status,
                httpVersion: "HTTP/1.1",
                headerFields: plan.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(0)
    }

    private func deliver(_ index: Int) {
        guard !cancelled else { return }
        if let failAfter = plan.failAfterChunk, index >= failAfter {
            client?.urlProtocol(self, didFailWithError: plan.error)
            return
        }
        guard index < chunks.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: chunks[index])
        let next = index + 1
        if plan.delayPerChunk > 0 {
            queue.asyncAfter(deadline: .now() + plan.delayPerChunk) { [weak self] in self?.deliver(next) }
        } else {
            queue.async { [weak self] in self?.deliver(next) }
        }
    }
}

// MARK: - 便于测试的构造器

func makeStubSettings(baseURL: String = "https://stub.local/v1") -> AppSettings.Translate {
    var settings = AppSettings.Translate(baseURL: baseURL)
    settings.modelStandard = "gpt-4o-mini"
    settings.modelAdvanced = "gpt-4o"
    settings.timeoutMs = 25_000
    return settings
}

func makeStubProvider(
    baseURL: String = "https://stub.local/v1",
    apiKey: String? = "sk-test-SECRET-key-123",
    policy: RequestPolicy = RequestPolicy(connectTimeout: 3, totalTimeout: 6, retryBackoff: 0.05, maxRetries: 1),
    stage2: Bool = false,
    cache: TranslateCache = TranslateCache()
) -> OpenAITranslateProvider {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 10
    let transport = URLSessionTransport(policy: policy, configuration: config)
    return OpenAITranslateProvider(
        settings: makeStubSettings(baseURL: baseURL),
        apiKeyProvider: { apiKey },
        transport: transport,
        policy: policy,
        cache: cache,
        stage2Enabled: stage2
    )
}

// MARK: - 机器翻译桩

func makeMachineSettings(
    service: MachineTranslationService = .auto,
    timeoutMs: Int = 8_000
) -> AppSettings.Translate {
    var settings = AppSettings.Translate()
    settings.engine = .machine
    settings.machineService = service
    settings.machineTimeoutMs = timeoutMs
    return settings
}

func makeStubMachineProvider(
    service: MachineTranslationService,
    policy: RequestPolicy = RequestPolicy(connectTimeout: 3, totalTimeout: 6, retryBackoff: 0.05, maxRetries: 0),
    cache: TranslateCache = TranslateCache()
) -> MachineTranslateProvider {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 10
    let transport = URLSessionTransport(policy: policy, configuration: config)
    return MachineTranslateProvider(
        settings: makeMachineSettings(service: service),
        transport: transport,
        cache: cache,
        policy: policy
    )
}

func youdaoBody(_ translation: [String], errorCode: String = "0") -> String {
    var object: [String: Any] = ["errorCode": errorCode, "translation": translation]
    if errorCode != "0" { object["translation"] = [String]() }
    return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
}

func myMemoryBody(_ text: String, status: Int = 200) -> String {
    let object: [String: Any] = [
        "responseStatus": status,
        "responseDetails": status == 200 ? "" : "QUOTA",
        "responseData": ["translatedText": text],
    ]
    return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
}

func googleBody(_ segments: [String]) -> String {
    let rows: [[Any]] = segments.map { [$0, "source", NSNull(), NSNull(), 10] }
    let root: [Any] = [rows, NSNull(), "en"]
    return String(decoding: (try? JSONSerialization.data(withJSONObject: root)) ?? Data(), as: UTF8.self)
}

func makeTranslateRequest(
    _ text: String,
    source: LangCode = .en,
    target: LangCode = .zhHans,
    tier: AiTier = .standard,
    mode: TranslateMode = .sentence
) -> TranslateRequest {
    TranslateRequest(text: text, pair: LanguagePair(source: source, target: target), tier: tier, mode: mode)
}

struct Collected {
    var text = ""
    var detail: TranslationDetail?
    var error: Error?
    var deltaCount = 0
    var elapsed: TimeInterval = 0
}

func collect(_ stream: AsyncThrowingStream<TranslateEvent, Error>) async -> Collected {
    var collected = Collected()
    let clock = ContinuousClock()
    let start = clock.now
    do {
        for try await event in stream {
            switch event {
            case .delta(let delta):
                collected.text += delta
                collected.deltaCount += 1
            case .detail(let detail):
                collected.detail = detail
            }
        }
    } catch {
        collected.error = error
    }
    collected.elapsed = start.duration(to: clock.now).timeInterval
    return collected
}

extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

// MARK: - 响应体构造

func jsonData(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
}

func streamBody(_ contents: [String]) -> String {
    var out = ""
    for content in contents {
        let object: [String: Any] = ["choices": [["delta": ["content": content]]]]
        out += "data: " + String(decoding: jsonData(object), as: UTF8.self) + "\n\n"
    }
    out += "data: [DONE]\n\n"
    return out
}

func completionBody(_ content: String) -> String {
    String(decoding: jsonData(["choices": [["message": ["content": content]]]]), as: UTF8.self)
}
