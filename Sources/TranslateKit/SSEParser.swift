import Foundation

/// 增量 SSE 解析器（文档 §10：必须覆盖 chunk 边界截断与畸形行）。
/// 只保留 `data:` 字段；空行派发一个事件；`[DONE]` 派发 .done；无法解析的行静默跳过。
public struct SSEParser {
    public enum Event: Equatable, Sendable {
        case data(String)
        case done
    }

    private var buffer: [UInt8] = []
    private var dataLines: [String] = []
    private(set) public var malformedLineCount: Int = 0

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Event] {
        buffer.append(contentsOf: chunk)
        var events: [Event] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineBytes = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if let event = consumeLine(String(decoding: lineBytes, as: UTF8.self)) {
                events.append(event)
            }
        }
        return events
    }

    /// 流结束时冲刷残留（最后一帧可能没有结尾空行）。
    public mutating func finish() -> [Event] {
        var events: [Event] = []
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if let event = consumeLine(line) { events.append(event) }
        }
        if let event = dispatchPending() { events.append(event) }
        return events
    }

    private mutating func consumeLine(_ rawLine: String) -> Event? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return dispatchPending() }
        if line.hasPrefix(":") { return nil } // 注释 / keep-alive
        guard let colon = line.firstIndex(of: ":") else {
            malformedLineCount += 1
            return nil
        }
        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "data" { dataLines.append(value) }
        return nil
    }

    private mutating func dispatchPending() -> Event? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { return .done }
        return .data(payload)
    }
}
