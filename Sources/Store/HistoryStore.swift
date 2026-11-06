import Foundation
import Contracts

/// 历史读写的模块内契约（AppShell 只依赖它，不碰 SQLite）。
public protocol HistoryStoring: AnyObject {
    func insert(_ entry: HistoryEntry) throws
    func update(_ entry: HistoryEntry) throws
    func entry(id: String) throws -> HistoryEntry?
    func recent(limit: Int) throws -> [HistoryEntry]
    func count() throws -> Int
    func delete(id: String) throws
    func deleteAll() throws
    /// 条目上限裁剪（文档 §6.7 history.limit）：只保留最新的 limit 条。
    func trim(to limit: Int) throws
}

/// 收藏（文档 §6.7 favorites 表）。
public protocol FavoriteStoring: AnyObject {
    func addFavorite(historyID: String, note: String?, createdAt: Int) throws
    func removeFavorite(historyID: String) throws
    func favorites() throws -> [Favorite]
}

public struct Favorite: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var note: String?
    public var createdAt: Int

    public init(id: String, note: String? = nil, createdAt: Int) {
        self.id = id
        self.note = note
        self.createdAt = createdAt
    }
}

/// 文档 §6.7 的建表语句（history / favorites / kv / idx_history_time）。
public enum StoreSchema {
    public static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS history(
          id TEXT PRIMARY KEY, created_at INTEGER NOT NULL,
          source_text TEXT NOT NULL, source_lang TEXT, target_lang TEXT NOT NULL,
          translation TEXT, detail_json TEXT, tier TEXT, model TEXT,
          source_kind TEXT,
          app_bundle_id TEXT, ocr_image_path TEXT, error TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS favorites(
          id TEXT PRIMARY KEY REFERENCES history(id), note TEXT, created_at INTEGER
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value BLOB)
        """,
        "CREATE INDEX IF NOT EXISTS idx_history_time ON history(created_at DESC)",
    ]

    public static func apply(to database: SQLiteDatabase) throws {
        for statement in statements { try database.execute(statement) }
    }
}

public final class SQLiteHistoryStore: HistoryStoring, FavoriteStoring, @unchecked Sendable {
    public let database: SQLiteDatabase
    private let lock = NSRecursiveLock()

    public init(database: SQLiteDatabase) throws {
        self.database = database
        try StoreSchema.apply(to: database)
    }

    public convenience init(path: String) throws {
        try self.init(database: SQLiteDatabase(path: path))
    }

    public convenience init(inMemory: Bool = true) throws {
        try self.init(database: SQLiteDatabase.inMemory())
    }

    private static let columns = "id, created_at, source_text, source_lang, target_lang, translation, detail_json, tier, model, source_kind, app_bundle_id, ocr_image_path, error"

    // MARK: 写

    public func insert(_ entry: HistoryEntry) throws {
        lock.lock(); defer { lock.unlock() }
        try database.withStatement(
            "INSERT OR REPLACE INTO history(\(Self.columns)) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)"
        ) { statement in
            try bind(entry, to: statement)
            try statement.step()
        }
    }

    public func update(_ entry: HistoryEntry) throws {
        lock.lock(); defer { lock.unlock() }
        try database.withStatement(
            """
            UPDATE history SET created_at=?2, source_text=?3, source_lang=?4, target_lang=?5, translation=?6,
              detail_json=?7, tier=?8, model=?9, source_kind=?10, app_bundle_id=?11, ocr_image_path=?12, error=?13
            WHERE id=?1
            """
        ) { statement in
            try bind(entry, to: statement)
            try statement.step()
        }
    }

    private func bind(_ entry: HistoryEntry, to statement: SQLiteStatement) throws {
        try statement.bind(1, entry.id)
        try statement.bind(2, Int64(entry.createdAt))
        try statement.bind(3, entry.sourceText)
        try statement.bind(4, entry.sourceLang?.rawValue)
        try statement.bind(5, entry.targetLang.rawValue)
        try statement.bind(6, entry.translation)
        try statement.bind(7, entry.detail.flatMap { try? JSONEncoder().encode($0) })
        try statement.bind(8, entry.tier?.rawValue)
        try statement.bind(9, entry.model)
        try statement.bind(10, entry.sourceKind.rawValue)
        try statement.bind(11, entry.appBundleID)
        try statement.bind(12, entry.ocrImagePath)
        try statement.bind(13, entry.error)
    }

    // MARK: 读

    public func entry(id: String) throws -> HistoryEntry? {
        lock.lock(); defer { lock.unlock() }
        return try database.withStatement("SELECT \(Self.columns) FROM history WHERE id = ?1 LIMIT 1") { statement in
            try statement.bind(1, id)
            guard try statement.step() else { return nil }
            return try decode(statement)
        }
    }

    public func recent(limit: Int) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        return try database.withStatement(
            "SELECT \(Self.columns) FROM history ORDER BY created_at DESC, rowid DESC LIMIT ?1"
        ) { statement in
            try statement.bind(1, Int64(limit))
            var rows: [HistoryEntry] = []
            while try statement.step() {
                rows.append(try decode(statement))
            }
            return rows
        }
    }

    public func count() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try database.withStatement("SELECT COUNT(*) FROM history") { statement in
            guard try statement.step(), let value = statement.int64(0) else { return 0 }
            return Int(value)
        }
    }

    private func decode(_ statement: SQLiteStatement) throws -> HistoryEntry {
        guard let id = statement.string(0), let sourceText = statement.string(2) else {
            throw StoreError.corruptRow("缺少 id 或 source_text")
        }
        let detail = statement.data(6).flatMap { try? JSONDecoder().decode(TranslationDetail.self, from: $0) }
        return HistoryEntry(
            id: id,
            createdAt: Int(statement.int64(1) ?? 0),
            sourceText: sourceText,
            sourceLang: statement.string(3).flatMap(LangCode.init(rawValue:)),
            targetLang: statement.string(4).flatMap(LangCode.init(rawValue:)) ?? .zhHans,
            translation: statement.string(5),
            detail: detail,
            tier: statement.string(7).flatMap(AiTier.init(rawValue:)),
            model: statement.string(8),
            sourceKind: statement.string(9).flatMap(SourceKind.init(rawValue:)) ?? .selection,
            appBundleID: statement.string(10),
            ocrImagePath: statement.string(11),
            error: statement.string(12)
        )
    }

    // MARK: 删

    public func delete(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try database.withStatement("DELETE FROM history WHERE id = ?1") { statement in
            try statement.bind(1, id)
            try statement.step()
        }
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        try database.execute("DELETE FROM history")
    }

    public func trim(to limit: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard limit >= 0 else { return }
        try database.withStatement(
            """
            DELETE FROM history WHERE id NOT IN (
              SELECT id FROM history ORDER BY created_at DESC, rowid DESC LIMIT ?1
            )
            """
        ) { statement in
            try statement.bind(1, Int64(limit))
            try statement.step()
        }
    }

    // MARK: 收藏

    public func addFavorite(historyID: String, note: String?, createdAt: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try database.withStatement(
            "INSERT OR REPLACE INTO favorites(id, note, created_at) VALUES(?1, ?2, ?3)"
        ) { statement in
            try statement.bind(1, historyID)
            try statement.bind(2, note)
            try statement.bind(3, Int64(createdAt))
            try statement.step()
        }
    }

    public func removeFavorite(historyID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try database.withStatement("DELETE FROM favorites WHERE id = ?1") { statement in
            try statement.bind(1, historyID)
            try statement.step()
        }
    }

    public func favorites() throws -> [Favorite] {
        lock.lock(); defer { lock.unlock() }
        return try database.withStatement("SELECT id, note, created_at FROM favorites ORDER BY created_at DESC") { statement in
            var rows: [Favorite] = []
            while try statement.step() {
                guard let id = statement.string(0) else { continue }
                rows.append(Favorite(id: id, note: statement.string(1), createdAt: Int(statement.int64(2) ?? 0)))
            }
            return rows
        }
    }
}
