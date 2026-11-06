import Testing
import Foundation
import Contracts
import Store

@Suite("历史存储（SQLite3，禁 GRDB）")
struct HistoryStoreTests {
    private func inMemoryStore() throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(inMemory: true)
    }

    private func tableNames(_ database: SQLiteDatabase) throws -> [String] {
        try database.withStatement(
            "SELECT name FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ) { statement in
            var names: [String] = []
            while try statement.step() {
                if let name = statement.string(0) { names.append(name) }
            }
            return names
        }
    }

    private func sample(
        id: String = "h1",
        createdAt: Int = 100,
        text: String = "hello",
        translation: String? = "你好",
        detail: TranslationDetail? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            id: id,
            createdAt: createdAt,
            sourceText: text,
            sourceLang: .en,
            targetLang: .zhHans,
            translation: translation,
            detail: detail,
            tier: .standard,
            model: "gpt-4o-mini",
            sourceKind: .selection,
            appBundleID: "com.apple.Safari"
        )
    }

    @Test("按文档 §6.7 建表：history / favorites / kv / idx_history_time")
    func schema() throws {
        let store = try inMemoryStore()
        let names = try tableNames(store.database)
        #expect(names.contains("history"))
        #expect(names.contains("favorites"))
        #expect(names.contains("kv"))
        #expect(names.contains("idx_history_time"))
    }

    @Test("插入后按时间倒序读取")
    func insertAndOrdering() throws {
        let store = try inMemoryStore()
        try store.insert(sample(id: "old", createdAt: 100, text: "old", translation: "旧"))
        try store.insert(sample(id: "new", createdAt: 300, text: "new", translation: "新"))
        try store.insert(sample(id: "mid", createdAt: 200, text: "mid", translation: "中"))

        let rows = try store.recent(limit: 10)
        #expect(rows.map(\.id) == ["new", "mid", "old"])
        #expect(try store.count() == 3)
        #expect(try store.recent(limit: 2).count == 2)
        #expect(try store.recent(limit: 0).isEmpty)
    }

    @Test("detail JSON 往返（词条/例句/近义/用法/备注）")
    func detailRoundTrip() throws {
        let store = try inMemoryStore()
        let detail = TranslationDetail(
            sourceLang: .en,
            targetLang: .zhHans,
            translation: "鸟",
            mode: .word,
            senses: [.init(pos: "n.", defs: [.init(def: "鸟；禽", examples: [.init(src: "a bird", tgt: "一只鸟")])])],
            synonyms: [.init(word: "fowl", note: "家禽")],
            usage: [.init(title: "give sb. the bird", body: "起哄")],
            notes: ["口语"]
        )
        try store.insert(sample(detail: detail))
        let loaded = try #require(try store.entry(id: "h1"))
        #expect(loaded.detail == detail)
        #expect(loaded.sourceLang == .en)
        #expect(loaded.tier == .standard)
        #expect(loaded.model == "gpt-4o-mini")
        #expect(loaded.appBundleID == "com.apple.Safari")
    }

    @Test("更新译文与错误标记")
    func update() throws {
        let store = try inMemoryStore()
        var entry = sample(translation: nil)
        try store.insert(entry)
        entry.translation = "你好"
        entry.error = nil
        try store.update(entry)
        #expect(try store.entry(id: "h1")?.translation == "你好")

        entry.error = "网络错误"
        entry.translation = nil
        try store.update(entry)
        let reloaded = try #require(try store.entry(id: "h1"))
        #expect(reloaded.error == "网络错误")
        #expect(reloaded.translation == nil)
    }

    @Test("删除单条 / 清空")
    func delete() throws {
        let store = try inMemoryStore()
        try store.insert(sample(id: "a", createdAt: 1))
        try store.insert(sample(id: "b", createdAt: 2))
        try store.delete(id: "a")
        #expect(try store.count() == 1)
        #expect(try store.entry(id: "a") == nil)
        try store.deleteAll()
        #expect(try store.count() == 0)
    }

    @Test("条目上限裁剪只保留最新 N 条")
    func trim() throws {
        let store = try inMemoryStore()
        for index in 0..<25 {
            try store.insert(sample(id: "h\(index)", createdAt: index, text: "t\(index)", translation: "译\(index)"))
        }
        #expect(try store.count() == 25)
        try store.trim(to: 10)
        let rows = try store.recent(limit: 100)
        #expect(rows.count == 10)
        #expect(rows.first?.id == "h24")
        #expect(rows.last?.id == "h15")
    }

    @Test("收藏增列删")
    func favorites() throws {
        let store = try inMemoryStore()
        try store.insert(sample(id: "h1"))
        try store.addFavorite(historyID: "h1", note: "常用", createdAt: 10)
        #expect(try store.favorites() == [Favorite(id: "h1", note: "常用", createdAt: 10)])
        try store.removeFavorite(historyID: "h1")
        #expect(try store.favorites().isEmpty)
    }

    @Test("两个内存库互不干扰；文件库可重开读回")
    func isolationAndPersistence() throws {
        let first = try inMemoryStore()
        let second = try inMemoryStore()
        try first.insert(sample(id: "only-first"))
        #expect(try first.count() == 1)
        #expect(try second.count() == 0)

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-test-" + UUID().uuidString)
            .appendingPathComponent("history.sqlite3")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        do {
            let store = try SQLiteHistoryStore(path: path.path)
            try store.insert(sample(id: "persisted", text: "落盘"))
        }
        let reopened = try SQLiteHistoryStore(path: path.path)
        #expect(try reopened.recent(limit: 5).first?.sourceText == "落盘")
    }

    @Test("无法打开的路径抛 StoreError")
    func openFailure() {
        #expect(throws: (any Error).self) {
            _ = try SQLiteHistoryStore(path: "/nonexistent-root-dir-for-test/store.sqlite3")
        }
    }

    @Test("导出 JSON 可被回读，字段与表结构一致")
    func exportJSON() throws {
        let store = try inMemoryStore()
        try store.insert(sample(id: "h1", createdAt: 42))
        try store.insert(sample(id: "h2", createdAt: 43, text: "second", translation: "第二"))

        let entries = try store.recent(limit: 10)
        let data = try HistoryExport.data(entries)
        let decoded = try HistoryExport.decode(data)
        #expect(decoded.count == 2)
        #expect(decoded.first?.sourceText == "second")

        let text = try HistoryExport.string(entries, prettyPrinted: false)
        #expect(text.contains("\"sourceText\""))
        #expect(text.contains("\"createdAt\""))
    }
}
