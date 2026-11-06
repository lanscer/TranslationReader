import Testing
import Foundation
import Contracts
import TranslateKit

@Suite("缓存键与 LRU/TTL")
struct TranslateCacheTests {
    @Test("键 = 引擎 + 归一化文本 + 语言对 + 档位 + 模式")
    func keyComposition() {
        let request = makeTranslateRequest("hello world")
        let normalizedA = TranslateCache.key(for: makeTranslateRequest("  hello   world "), engine: .machine)
        let normalizedB = TranslateCache.key(for: request, engine: .machine)
        #expect(normalizedA == normalizedB)

        let otherPair = TranslateCache.key(for: makeTranslateRequest("hello world", target: .ja), engine: .machine)
        let otherTier = TranslateCache.key(for: makeTranslateRequest("hello world", tier: .advanced), engine: .machine)
        let otherMode = TranslateCache.key(for: makeTranslateRequest("hello world", mode: .ocr), engine: .machine)
        let otherEngine = TranslateCache.key(for: request, engine: .ai)
        #expect(otherPair != normalizedA)
        #expect(otherTier != normalizedA)
        #expect(otherMode != normalizedA)
        #expect(otherEngine != normalizedA)
    }

    @Test("全角空格与换行也归一")
    func unicodeNormalization() {
        #expect(TranslateCache.normalized("\n 你好\u{3000}世界 \n") == "你好 世界")
    }

    @Test("TTL 过期后不再命中")
    func ttlExpiry() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let cache = TranslateCache(capacity: 8, ttl: 30, clock: { now })
        let request = makeTranslateRequest("bird")
        await cache.store(request, engine: .machine, translation: "鸟", detail: nil)
        #expect(await cache.value(for: request, engine: .machine)?.translation == "鸟")
        now = now.addingTimeInterval(31)
        #expect(await cache.value(for: request, engine: .machine) == nil)
        #expect(await cache.count == 0)
    }

    @Test("容量上限触发 LRU 淘汰")
    func lruEviction() async {
        let cache = TranslateCache(capacity: 2, ttl: 3600)
        let first = makeTranslateRequest("one")
        let second = makeTranslateRequest("two")
        let third = makeTranslateRequest("three")
        await cache.store(first, engine: .machine, translation: "一", detail: nil)
        await cache.store(second, engine: .machine, translation: "二", detail: nil)
        _ = await cache.value(for: first, engine: .machine) // first 变成最近使用
        await cache.store(third, engine: .machine, translation: "三", detail: nil)
        #expect(await cache.count == 2)
        #expect(await cache.value(for: second, engine: .machine) == nil)
        #expect(await cache.value(for: first, engine: .machine) != nil)
        #expect(await cache.value(for: third, engine: .machine) != nil)
    }
}
