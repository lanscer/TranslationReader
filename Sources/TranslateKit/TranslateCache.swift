import Foundation
import Contracts

/// 译文 + 细节缓存（文档 §6.5：TTL 30min、LRU 200、键 = text+pair+tier+mode 归一化）。
public actor TranslateCache {
    public struct Entry: Sendable, Equatable {
        public var translation: String
        public var detail: TranslationDetail?
        public var storedAt: Date

        public init(translation: String, detail: TranslationDetail? = nil, storedAt: Date = Date()) {
            self.translation = translation
            self.detail = detail
            self.storedAt = storedAt
        }
    }

    public let capacity: Int
    public let ttl: TimeInterval
    private var storage: [String: Entry] = [:]
    private var order: [String] = []
    private var clock: @Sendable () -> Date

    public init(capacity: Int = 200, ttl: TimeInterval = 1800, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = capacity
        self.ttl = ttl
        self.clock = clock
    }

    public var count: Int { storage.count }

    public static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.precomposedStringWithCanonicalMapping
    }

    /// 缓存键带上引擎：同一个词用机器翻译与 AI 翻译的译文不同，不能互相命中。
    public static func key(for request: TranslateRequest, engine: TranslationEngineKind) -> String {
        [
            engine.rawValue,
            normalized(request.text),
            request.pair.source.rawValue + ">" + request.pair.target.rawValue,
            request.tier.rawValue,
            request.mode.rawValue,
        ].joined(separator: "\u{1F}")
    }

    public func value(for request: TranslateRequest, engine: TranslationEngineKind) -> Entry? {
        let key = Self.key(for: request, engine: engine)
        guard let entry = storage[key] else { return nil }
        if clock().timeIntervalSince(entry.storedAt) > ttl {
            storage.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        touch(key)
        return entry
    }

    public func store(
        _ request: TranslateRequest,
        engine: TranslationEngineKind,
        translation: String,
        detail: TranslationDetail?
    ) {
        let key = Self.key(for: request, engine: engine)
        storage[key] = Entry(translation: translation, detail: detail, storedAt: clock())
        touch(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
