import Foundation
import SQLite3

/// SQLite3 C API 的最小封装（文档 §5.1：禁 GRDB，零第三方依赖）。
public enum StoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case openFailed(code: Int32, message: String)
    case statementFailed(code: Int32, message: String)
    case corruptRow(String)

    public var description: String {
        switch self {
        case .openFailed(let code, let message): return "打开数据库失败 (\(code)): \(message)"
        case .statementFailed(let code, let message): return "SQL 失败 (\(code)): \(message)"
        case .corruptRow(let message): return "数据行损坏: \(message)"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteDatabase: @unchecked Sendable {
    public let path: String
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        self.path = path
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &pointer, flags, nil)
        guard status == SQLITE_OK, let opened = pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 返回 \(status)"
            if let pointer { sqlite3_close_v2(pointer) }
            throw StoreError.openFailed(code: status, message: message)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 3000)
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw StoreError.statementFailed(code: SQLITE_MISUSE, message: "数据库已关闭") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard status == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            if let errorPointer { sqlite3_free(errorPointer) }
            throw StoreError.statementFailed(code: status, message: message)
        }
        if let errorPointer { sqlite3_free(errorPointer) }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw StoreError.statementFailed(code: SQLITE_MISUSE, message: "数据库已关闭") }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw StoreError.statementFailed(code: status, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(handle: statement)
    }

    public func withStatement<T>(_ sql: String, _ body: (SQLiteStatement) throws -> T) throws -> T {
        let statement = try prepare(sql)
        return try body(statement)
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changedRowCount: Int {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

public final class SQLiteStatement {
    private var handle: OpaquePointer?

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let handle { sqlite3_finalize(handle) }
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else {
            throw StoreError.statementFailed(code: SQLITE_MISUSE, message: "语句已释放")
        }
        return handle
    }

    public func bind(_ index: Int32, _ value: String?) throws {
        let handle = try requireHandle()
        let status: Int32
        if let value {
            status = sqlite3_bind_text(handle, index, value, -1, sqliteTransient)
        } else {
            status = sqlite3_bind_null(handle, index)
        }
        guard status == SQLITE_OK else {
            throw StoreError.statementFailed(code: status, message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
        }
    }

    public func bind(_ index: Int32, _ value: Int64?) throws {
        let handle = try requireHandle()
        let status = value.map { sqlite3_bind_int64(handle, index, $0) } ?? sqlite3_bind_null(handle, index)
        guard status == SQLITE_OK else {
            throw StoreError.statementFailed(code: status, message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
        }
    }

    public func bind(_ index: Int32, _ value: Data?) throws {
        let handle = try requireHandle()
        let status: Int32
        if let value {
            status = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
            }
        } else {
            status = sqlite3_bind_null(handle, index)
        }
        guard status == SQLITE_OK else {
            throw StoreError.statementFailed(code: status, message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
        }
    }

    /// 返回 true 表示取到一行。
    @discardableResult
    public func step() throws -> Bool {
        let handle = try requireHandle()
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw StoreError.statementFailed(code: status, message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
        }
    }

    public func reset() {
        guard let handle else { return }
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    public func string(_ column: Int32) -> String? {
        guard let handle else { return nil }
        guard let pointer = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: pointer)
    }

    public func int64(_ column: Int32) -> Int64? {
        guard let handle else { return nil }
        if sqlite3_column_type(handle, column) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(handle, column)
    }

    public func data(_ column: Int32) -> Data? {
        guard let handle else { return nil }
        guard let pointer = sqlite3_column_blob(handle, column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        return Data(bytes: pointer, count: count)
    }
}
