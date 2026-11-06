import AppKit

/// 剪贴板快照：保存 NSPasteboard 的**全量项**（含自定义类型，不只是纯文本）。
public struct PasteboardSnapshot {
    struct Item {
        var data: [NSPasteboard.PasteboardType: Data]
    }

    let changeCount: Int
    let items: [Item]

    public init(pasteboard: NSPasteboard = .general) {
        changeCount = pasteboard.changeCount
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) {
                    data[type] = value
                }
            }
            return Item(data: data)
        }
    }

    public var itemCount: Int { items.count }

    public var isEmpty: Bool { items.isEmpty }

    /// 写回快照。调用方必须先用 ClipboardArbiter 判断用户是否改动过。
    public func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.data {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(restored)
    }
}

public enum ClipboardRestoreDecision: Equatable, Sendable {
    /// 期间只有我们自己的合成 ⌘C 写过剪贴板 → 恢复用户原内容。
    case restore
    /// 期间用户自己改过剪贴板 → 保留用户内容，绝不覆盖。
    case keepUserContent
}

/// 文档 §6.1：用 changeCount 前后比对判定用户是否在此期间改动过剪贴板。
/// 纯逻辑，单测直接覆盖。
public enum ClipboardArbiter {
    /// - Parameters:
    ///   - copiedAtChangeCount: 读到我们自己 ⌘C 结果那一刻的 changeCount
    ///   - observedChangeCount: 准备恢复前再次读到的 changeCount
    public static func decide(copiedAtChangeCount: Int, observedChangeCount: Int) -> ClipboardRestoreDecision {
        observedChangeCount == copiedAtChangeCount ? .restore : .keepUserContent
    }
}
