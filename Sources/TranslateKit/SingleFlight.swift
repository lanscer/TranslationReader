import Foundation

/// 增量下发的接收端。用类型而不是闭包，避免把非逃逸闭包传进异步任务。
public final class DeltaSink: @unchecked Sendable {
    private let handler: @Sendable (String) async -> Void

    public init(_ handler: @escaping @Sendable (String) async -> Void) {
        self.handler = handler
    }

    public func emit(_ delta: String) async {
        await handler(delta)
    }
}

/// 单飞：同一 (文本, 语言对, 档位, 模式) 的并发 Stage1 请求合并成一次网络调用（文档 §5.4）。
actor Stage1Coalescer {
    private struct Group {
        var members: [UUID: AsyncThrowingStream<String, Error>.Continuation] = [:]
        var sent: [String] = []
    }

    private var groups: [String: Group] = [:]

    func stream(
        for key: String,
        produce: @escaping @Sendable (DeltaSink) async throws -> Void
    ) -> AsyncThrowingStream<String, Error> {
        let id = UUID()
        return AsyncThrowingStream<String, Error>(bufferingPolicy: .unbounded) { continuation in
            let attachTask = Task {
                await self.attach(key: key, id: id, continuation: continuation, produce: produce)
            }
            continuation.onTermination = { _ in
                attachTask.cancel()
                Task { await self.detach(key: key, id: id) }
            }
        }
    }

    private func attach(
        key: String,
        id: UUID,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        produce: @escaping @Sendable (DeltaSink) async throws -> Void
    ) {
        if var existing = groups[key], !existing.members.isEmpty {
            for delta in existing.sent { continuation.yield(delta) }
            existing.members[id] = continuation
            groups[key] = existing
            return
        }
        var group = Group()
        group.members[id] = continuation
        groups[key] = group
        let sink = DeltaSink { delta in await self.broadcast(key: key, delta: delta) }
        Task {
            do {
                try await produce(sink)
                self.finish(key: key, error: nil)
            } catch {
                self.finish(key: key, error: error)
            }
        }
    }

    private func broadcast(key: String, delta: String) {
        guard var group = groups[key] else { return }
        group.sent.append(delta)
        for continuation in group.members.values { continuation.yield(delta) }
        groups[key] = group
    }

    private func finish(key: String, error: Error?) {
        guard let group = groups.removeValue(forKey: key) else { return }
        for continuation in group.members.values {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func detach(key: String, id: UUID) {
        guard var group = groups[key] else { return }
        group.members[id] = nil
        groups[key] = group.members.isEmpty ? nil : group
    }
}

/// Stage2 是非流式请求：直接共享同一个 Task，天然单飞。
actor Stage2Coalescer {
    private var tasks: [String: Task<TranslationDetailBox?, Never>] = [:]

    func detail(
        key: String,
        produce: @escaping @Sendable () async -> TranslationDetailBox?
    ) async -> TranslationDetailBox? {
        if let existing = tasks[key] { return await existing.value }
        let task = Task { await produce() }
        tasks[key] = task
        let value = await task.value
        tasks[key] = nil
        return value
    }
}
