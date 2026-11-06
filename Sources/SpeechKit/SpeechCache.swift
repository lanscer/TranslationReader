import CryptoKit
import Foundation

/// 一句合成的缓存身份：文件名 = sha256(text|model|speaker|speed)（文档 §6.6.1）。
public struct SpeechCacheKey: Hashable, Sendable {
    public let text: String
    public let model: String
    public let speaker: Int
    public let speed: Float

    public init(text: String, model: String, speaker: Int, speed: Float) {
        self.text = text
        self.model = model
        self.speaker = speaker
        self.speed = speed
    }

    /// 参与哈希的原料；顺序与分隔符一旦改动即会让历史缓存全部失效。
    public var material: String {
        text + "|" + model + "|" + String(speaker) + "|" + String(format: "%.2f", speed)
    }

    public var digest: String {
        SpeechCache.sha256Hex(material)
    }
}

/// 合成 wav 的磁盘缓存，LRU 上限 500 条。
public final class SpeechCache {
    public static let defaultLimit = 500

    public let directory: URL
    public let limit: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        directory: URL = SpeechCache.defaultDirectory,
        limit: Int = SpeechCache.defaultLimit,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.limit = limit
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// ~/Library/Caches/TranslationReader/tts/
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("TranslationReader", isDirectory: true)
            .appendingPathComponent("tts", isDirectory: true)
    }

    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func url(for key: SpeechCacheKey) -> URL {
        directory.appendingPathComponent(key.digest + ".wav")
    }

    /// 命中返回本地 wav 并刷新 LRU 时间戳。
    public func lookup(_ key: SpeechCacheKey) -> URL? {
        let path = url(for: key)
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        touch(path)
        return path
    }

    /// 把刚合成好的临时 wav 收进缓存（幂等：已存在则丢弃临时文件）。
    @discardableResult
    public func store(_ tempURL: URL, for key: SpeechCacheKey) throws -> URL {
        let destination = url(for: key)
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: tempURL)
            touch(destination)
            return destination
        }
        try fileManager.moveItem(at: tempURL, to: destination)
        touch(destination)
        return destination
    }

    /// 当前缓存条数。
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return files().count
    }

    /// 超过上限时按最久未用删除（LRU）。
    public func pruneIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        let entries = files()
        guard entries.count > limit else { return }
        let overflow = entries.count - limit
        for url in entries
            .sorted(by: { accessDate($0) < accessDate($1) })
            .prefix(overflow) {
            try? fileManager.removeItem(at: url)
        }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for url in files() { try? fileManager.removeItem(at: url) }
    }

    private func files() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "wav" } ?? []
    }

    private func accessDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// 触碰文件 mtime，作为 LRU 的访问时间。
    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
