import Foundation
import Contracts

// Store：SQLite3（禁 GRDB）+ Keychain，见文档 §6.7。
public enum Store {
    public static let moduleName = "Store"

    /// apiKey 在 Keychain 的定位（文档 §6.7 末段）。
    public static let keychainService = "com.local.translationreader"
    public static let keychainAccount = "translate.apiKey"

    /// 默认库位置：~/Library/Application Support/TranslationReader/store.sqlite3
    public static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let bases = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base = bases.first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base
            .appendingPathComponent("TranslationReader", isDirectory: true)
            .appendingPathComponent("store.sqlite3")
    }

    /// 打开（必要时创建）默认位置的数据库。
    public static func openDefaultStore(fileManager: FileManager = .default) throws -> SQLiteHistoryStore {
        let url = defaultDatabaseURL(fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try SQLiteHistoryStore(path: url.path)
    }

    /// 契约：Contracts.HistoryEntry / SourceKind + AppSettings。
    public static func makeHistoryStub() -> [HistoryEntry] { [] }
}
