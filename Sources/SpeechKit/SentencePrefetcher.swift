import Foundation

/// 分句预取队列：容量 = 预取深度（文档 §6.6「队列（≤3 句预取）」）。
///
/// 生产者必须先 acquire 到槽位才能合成，消费者 take 到音频后释放槽位，
/// 因此「已合成但还没播」的句子最多 capacity 句。
actor SentencePrefetcher {
    private let capacity: Int
    private var ready: [Int: URL] = [:]
    private var failures: [Int: Error] = [:]
    private var waiters: [Int: CheckedContinuation<URL, Error>] = [:]
    private var slots: Int
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int) {
        let clamped = max(1, capacity)
        self.capacity = clamped
        self.slots = clamped
    }

    /// 生产者占用一个预取槽位（满了就挂起）。
    func acquire() async {
        if slots > 0 {
            slots -= 1
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    /// 生产者交付一句合成结果。
    func push(_ index: Int, _ url: URL) {
        if let waiter = waiters.removeValue(forKey: index) {
            waiter.resume(returning: url)
            releaseSlot()
        } else {
            ready[index] = url
        }
    }

    /// 生产者汇报某句失败，消费者会立刻拿到同一个错误。
    func fail(_ index: Int, _ error: Error) {
        if let waiter = waiters.removeValue(forKey: index) {
            waiter.resume(throwing: error)
            releaseSlot()
        } else {
            failures[index] = error
        }
    }

    /// 消费者取第 index 句的 wav（尚未合成则挂起等待）。
    func take(_ index: Int) async throws -> URL {
        if let url = ready.removeValue(forKey: index) {
            releaseSlot()
            return url
        }
        if let error = failures.removeValue(forKey: index) {
            releaseSlot()
            throw error
        }
        return try await withCheckedThrowingContinuation { waiters[index] = $0 }
    }

    /// 当前已就绪但未被取走的句数（单测用）。
    var bufferedCount: Int { ready.count }

    private func releaseSlot() {
        if let waiter = slotWaiters.first {
            slotWaiters.removeFirst()
            waiter.resume()
        } else {
            slots += 1
        }
    }
}
