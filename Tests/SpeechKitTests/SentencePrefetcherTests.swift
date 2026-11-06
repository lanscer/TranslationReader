import Foundation
@testable import SpeechKit
import Testing

/// 跨线程读写布尔标记。
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func mark() {
        lock.lock(); stored = true; lock.unlock()
    }
}

@Suite("预取队列（≤3 句）")
struct SentencePrefetcherTests {
    @Test("按序取回已合成音频")
    func takeInOrder() async throws {
        let prefetcher = SentencePrefetcher(capacity: 3)
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/s\($0).wav") }
        for (index, url) in urls.enumerated() {
            await prefetcher.acquire()
            await prefetcher.push(index, url)
        }
        for (index, url) in urls.enumerated() {
            let taken = try await prefetcher.take(index)
            #expect(taken == url)
        }
    }

    @Test("容量 3：第 4 句合成被挂起，播完一句才放行")
    func capacityBlocksFourth() async throws {
        let prefetcher = SentencePrefetcher(capacity: 3)
        for index in 0..<3 {
            await prefetcher.acquire()
            await prefetcher.push(index, URL(fileURLWithPath: "/tmp/p\(index).wav"))
        }
        let released = Latch()
        let blocked = Task {
            await prefetcher.acquire()
            released.mark()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(released.value == false, "容量 3 时第 4 句必须挂起")

        _ = try await prefetcher.take(0)
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(released.value == true, "取走一句后第 4 句应被放行")
        blocked.cancel()
    }

    @Test("合成失败原样抛给消费者")
    func failurePropagates() async {
        let prefetcher = SentencePrefetcher(capacity: 2)
        await prefetcher.acquire()
        await prefetcher.fail(0, SherpaError.modelMissing(model: "m", path: "/tmp/x"))
        do {
            _ = try await prefetcher.take(0)
            Issue.record("应当抛错")
        } catch let error as SherpaError {
            #expect(error == .modelMissing(model: "m", path: "/tmp/x"))
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }
}
