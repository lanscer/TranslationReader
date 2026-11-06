import Foundation
import SpeechKit
import Testing

@Suite("合成缓存")
struct SpeechCacheTests {
    func makeTempCache(limit: Int = 500) throws -> (SpeechCache, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechkit-cache-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SpeechCache(directory: dir, limit: limit), dir)
    }

    @Test("文件名 = sha256(text|model|speaker|speed)")
    func digestStable() {
        let key = SpeechCacheKey(text: "你好", model: "vits-piper-zh_CN-huayan-medium", speaker: 0, speed: 1.0)
        #expect(key.material == "你好|vits-piper-zh_CN-huayan-medium|0|1.00")
        #expect(key.digest.count == 64)
        let same = SpeechCacheKey(text: "你好", model: "vits-piper-zh_CN-huayan-medium", speaker: 0, speed: 1.0)
        #expect(key.digest == same.digest)
        let other = SpeechCacheKey(text: "你好", model: "vits-piper-zh_CN-huayan-medium", speaker: 0, speed: 1.5)
        #expect(key.digest != other.digest)
    }

    @Test("未命中 → 存入 → 命中")
    func storeAndLookup() throws {
        let (cache, dir) = try makeTempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SpeechCacheKey(text: "abc", model: "m", speaker: 0, speed: 1.0)
        #expect(cache.lookup(key) == nil)

        let temp = cache.directory.appendingPathComponent("temp.wav")
        try Data(repeating: 7, count: 64).write(to: temp)
        let stored = try cache.store(temp, for: key)

        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect(stored.lastPathComponent == key.digest + ".wav")
        #expect(cache.lookup(key)?.path == stored.path)
        #expect(cache.count == 1)
    }

    @Test("重复存入幂等，不报错不留垃圾")
    func idempotentStore() throws {
        let (cache, dir) = try makeTempCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SpeechCacheKey(text: "abc", model: "m", speaker: 0, speed: 1.0)
        let first = cache.directory.appendingPathComponent("a.wav")
        try Data(repeating: 1, count: 32).write(to: first)
        let stored = try cache.store(first, for: key)

        let second = cache.directory.appendingPathComponent("b.wav")
        try Data(repeating: 2, count: 32).write(to: second)
        let again = try cache.store(second, for: key)

        #expect(again.path == stored.path)
        #expect(cache.count == 1)
        #expect(FileManager.default.fileExists(atPath: second.path) == false)
    }

    @Test("超过上限时按最久未用淘汰")
    func lruPrune() async throws {
        let (cache, dir) = try makeTempCache(limit: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<3 {
            let key = SpeechCacheKey(text: "s\(index)", model: "m", speaker: 0, speed: 1.0)
            let temp = cache.directory.appendingPathComponent("t\(index).wav")
            try Data(repeating: UInt8(index), count: 8).write(to: temp)
            _ = try cache.store(temp, for: key)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        cache.pruneIfNeeded()
        #expect(cache.count == 2)
        let oldest = SpeechCacheKey(text: "s0", model: "m", speaker: 0, speed: 1.0)
        #expect(cache.lookup(oldest) == nil)
    }
}
