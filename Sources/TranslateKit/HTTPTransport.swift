import Foundation

public struct HTTPResponseHead: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }
}

public enum HTTPStreamEvent: Sendable {
    case head(HTTPResponseHead)
    case body(Data)
}

/// 网络层抽象：生产实现走 URLSession，测试用 URLProtocol 桩注入（文档 §10）。
public protocol HTTPTransport: AnyObject, Sendable {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error>
}

public enum TransportError: Error, Equatable, Sendable {
    case timedOut(TimeInterval)
    case cancelled
}

/// 文档 §6.5 的超时与重试口径。
public struct RequestPolicy: Sendable, Equatable {
    /// 等到响应头的最长时间（连接阶段）。
    public var connectTimeout: TimeInterval
    /// 单次请求从发出到结束的总时长。
    public var totalTimeout: TimeInterval
    /// 429 / 5xx 的退避间隔。
    public var retryBackoff: TimeInterval
    /// 429 / 5xx 最多重试次数。
    public var maxRetries: Int

    public init(
        connectTimeout: TimeInterval = 5,
        totalTimeout: TimeInterval = 25,
        retryBackoff: TimeInterval = 0.8,
        maxRetries: Int = 1
    ) {
        self.connectTimeout = connectTimeout
        self.totalTimeout = totalTimeout
        self.retryBackoff = retryBackoff
        self.maxRetries = maxRetries
    }
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let policy: RequestPolicy

    public init(policy: RequestPolicy = RequestPolicy(), configuration: URLSessionConfiguration? = nil) {
        self.policy = policy
        if let configuration {
            self.configuration = configuration
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = policy.totalTimeout
            config.timeoutIntervalForResource = policy.totalTimeout
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            self.configuration = config
        }
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        let policy = self.policy
        let configuration = self.configuration
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let delegate = StreamDelegate(policy: policy, continuation: continuation)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            delegate.attach(session: session)
            let task = session.dataTask(with: request)
            delegate.start(task: task)
            continuation.onTermination = { _ in delegate.cancel() }
        }
    }
}

/// 把 URLSession 的数据回调转成 AsyncThrowingStream，同时守住连接/总时长两条超时线。
private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let policy: RequestPolicy
    private let continuation: AsyncThrowingStream<HTTPStreamEvent, Error>.Continuation
    private let lock = NSLock()
    private let timers = DispatchQueue(label: "com.local.translationreader.translatekit.transport-timer")

    private var connectTimer: DispatchSourceTimer?
    private var totalTimer: DispatchSourceTimer?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false

    init(policy: RequestPolicy, continuation: AsyncThrowingStream<HTTPStreamEvent, Error>.Continuation) {
        self.policy = policy
        self.continuation = continuation
        super.init()
    }

    func attach(session: URLSession) {
        lock.lock(); self.session = session; lock.unlock()
    }

    func start(task: URLSessionDataTask) {
        lock.lock(); self.task = task; lock.unlock()
        let connect = makeTimer(after: policy.connectTimeout) { [weak self] in
            guard let self else { return }
            self.fireTimeout(self.policy.connectTimeout)
        }
        let total = makeTimer(after: policy.totalTimeout) { [weak self] in
            guard let self else { return }
            self.fireTimeout(self.policy.totalTimeout)
        }
        lock.lock()
        connectTimer = connect
        totalTimer = total
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        let session = self.session
        finished = true
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        disarmTimers()
    }

    private func makeTimer(after seconds: TimeInterval, _ body: @escaping @Sendable () -> Void) -> DispatchSourceTimer? {
        guard seconds > 0 else { return nil }
        let timer = DispatchSource.makeTimerSource(queue: timers)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: body)
        timer.resume()
        return timer
    }

    private func disarmTimers() {
        lock.lock()
        let timers = [connectTimer, totalTimer]
        connectTimer = nil
        totalTimer = nil
        lock.unlock()
        timers.forEach { $0?.cancel() }
    }

    private func fireTimeout(_ seconds: TimeInterval) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let task = self.task
        let session = self.session
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        disarmTimers()
        continuation.finish(throwing: TransportError.timedOut(seconds))
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session_: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let connect = connectTimer
        connectTimer = nil
        lock.unlock()
        connect?.cancel()

        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        if let all = http?.allHeaderFields {
            for (key, value) in all {
                if let key = key as? String { headers[key.lowercased()] = "\(value)" }
            }
        }
        continuation.yield(.head(HTTPResponseHead(statusCode: http?.statusCode ?? 0, headers: headers)))
        completionHandler(.allow)
    }

    func urlSession(_ session_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let done = finished
        lock.unlock()
        if done { return }
        continuation.yield(.body(data))
    }

    func urlSession(_ session_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        disarmTimers()
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                continuation.finish(throwing: TransportError.cancelled)
            } else {
                continuation.finish(throwing: error)
            }
        } else {
            continuation.finish()
        }
    }
}
