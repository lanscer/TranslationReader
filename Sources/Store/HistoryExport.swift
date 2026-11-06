import Foundation
import Contracts

/// 历史导出 JSON（文档 §6.7 的 history 表结构，便于用户自带分析）。
public enum HistoryExport {
    public static func data(_ entries: [HistoryEntry], prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entries)
    }

    public static func string(_ entries: [HistoryEntry], prettyPrinted: Bool = true) throws -> String {
        let data = try data(entries, prettyPrinted: prettyPrinted)
        return String(decoding: data, as: UTF8.self)
    }

    public static func write(_ entries: [HistoryEntry], to url: URL, prettyPrinted: Bool = true) throws {
        try data(entries, prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
    }

    public static func decode(_ data: Data) throws -> [HistoryEntry] {
        try JSONDecoder().decode([HistoryEntry].self, from: data)
    }
}
