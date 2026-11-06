import Foundation
import CoreGraphics
import Contracts

/// 行聚合参数（文档 §6.3：按 boundingBox.minY 降序聚合，阈值 = 行高 0.5）。
public struct OcrLayoutConfig: Sendable, Hashable {
    /// 同行判定：两行的 minY 差值 / 行高 的容忍比例。
    public var rowThresholdRatio: CGFloat
    /// 同段落判定：行距 / 行高 的上限比例（超出则另起段落）。
    public var paragraphGapRatio: CGFloat
    /// 多列判定：列间空白 / 中位行高 的下限比例。
    public var columnGapRatio: CGFloat
    /// 竖排判定：单个字框高 / 宽 的下限比例。
    public var verticalAspectRatio: CGFloat
    /// 竖排判定：满足 verticalAspectRatio 的行占比下限。
    public var verticalShareRatio: CGFloat

    public init(rowThresholdRatio: CGFloat = 0.5,
                // 0.8 会把列表项（项间距约 0.75 行高）误并成一段；0.5 仍能合并正文折行（约 0.4 行高）。
                paragraphGapRatio: CGFloat = 0.5,
                columnGapRatio: CGFloat = 0.6,
                verticalAspectRatio: CGFloat = 1.4,
                verticalShareRatio: CGFloat = 0.6) {
        self.rowThresholdRatio = rowThresholdRatio
        self.paragraphGapRatio = paragraphGapRatio
        self.columnGapRatio = columnGapRatio
        self.verticalAspectRatio = verticalAspectRatio
        self.verticalShareRatio = verticalShareRatio
    }
}

/// 一个段落：同一语义块内的行，已按阅读顺序拼成一行文本。
public struct OcrParagraph: Sendable, Hashable {
    public let text: String
    public let lines: [OcrLine]
    public let isVertical: Bool

    public init(text: String, lines: [OcrLine], isVertical: Bool) {
        self.text = text
        self.lines = lines
        self.isVertical = isVertical
    }
}

/// 版面分析结果：段落顺序即阅读顺序（多列左→右、竖排右→左）。
public struct OcrLayout: Sendable, Hashable {
    public let paragraphs: [OcrParagraph]
    public let readingOrder: [OcrLine]
    public let isVertical: Bool

    public init(paragraphs: [OcrParagraph], readingOrder: [OcrLine], isVertical: Bool) {
        self.paragraphs = paragraphs
        self.readingOrder = readingOrder
        self.isVertical = isVertical
    }

    /// 段落文本，段落之间保留换行（文档 §6.3「保留换行」）。
    public var text: String {
        paragraphs.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// 纯函数版面后处理：不依赖 Vision，可用合成 OcrLine 直接在单测里验证。
public enum OcrPostProcessor {

    public static func layout(_ lines: [OcrLine], config: OcrLayoutConfig = OcrLayoutConfig()) -> OcrLayout {
        let usable = lines.filter { line in
            !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && line.box.width > 0 && line.box.height > 0
        }
        guard !usable.isEmpty else {
            return OcrLayout(paragraphs: [], readingOrder: [], isVertical: false)
        }
        return isVertical(usable, config: config)
            ? verticalLayout(usable, config: config)
            : horizontalLayout(usable, config: config)
    }

    // MARK: - 竖排 / 横排判定

    static func isVertical(_ lines: [OcrLine], config: OcrLayoutConfig) -> Bool {
        guard lines.count >= 2 else { return false }
        let tall = lines.filter { $0.box.height > $0.box.width * config.verticalAspectRatio }.count
        return CGFloat(tall) / CGFloat(lines.count) >= config.verticalShareRatio
    }

    // MARK: - 横排

    static func horizontalLayout(_ lines: [OcrLine], config: OcrLayoutConfig) -> OcrLayout {
        let medianHeight = median(lines.map { $0.box.height })
        let columns = splitColumns(lines, gapThreshold: medianHeight * config.columnGapRatio)

        var paragraphs: [OcrParagraph] = []
        for column in columns {
            let rows = groupRows(column, toleranceRatio: config.rowThresholdRatio)
            paragraphs.append(contentsOf: horizontalParagraphs(rows, config: config))
        }
        return OcrLayout(paragraphs: paragraphs, readingOrder: paragraphs.flatMap(\.lines), isVertical: false)
    }

    /// 按 x 投影重叠把行切成列，返回顺序 = 左→右。
    static func splitColumns(_ lines: [OcrLine], gapThreshold: CGFloat) -> [[OcrLine]] {
        guard lines.count > 1 else { return [lines] }
        let spans = lines.map { ($0.box.minX, $0.box.maxX) }.sorted { $0.0 < $1.0 }
        var merged: [(min: CGFloat, max: CGFloat)] = []
        for span in spans {
            if let last = merged.last, span.0 <= last.max {
                merged[merged.count - 1].max = Swift.max(last.max, span.1)
            } else {
                merged.append((span.0, span.1))
            }
        }
        // 只把空白超过阈值的相邻区间视为列分隔；否则合并成一列。
        var columns: [(min: CGFloat, max: CGFloat)] = []
        for span in merged {
            if let last = columns.last, span.min - last.max <= gapThreshold {
                columns[columns.count - 1].max = Swift.max(last.max, span.max)
            } else {
                columns.append(span)
            }
        }
        guard columns.count > 1 else { return [lines] }

        var buckets: [[OcrLine]] = Array(repeating: [], count: columns.count)
        for line in lines {
            let centerX = line.box.midX
            if let index = columns.firstIndex(where: { centerX >= $0.min && centerX <= $0.max }) {
                buckets[index].append(line)
            } else {
                var best = 0
                var bestDistance = CGFloat.greatestFiniteMagnitude
                for (index, column) in columns.enumerated() {
                    let distance = Swift.min(abs(centerX - column.min), abs(centerX - column.max))
                    if distance < bestDistance { bestDistance = distance; best = index }
                }
                buckets[best].append(line)
            }
        }
        let nonEmpty = buckets.filter { !$0.isEmpty }
        return nonEmpty.count > 1 ? nonEmpty : [lines]
    }

    /// 按 boundingBox.minY 降序（上→下）聚合为行，行内按 minX 升序（左→右）。
    static func groupRows(_ lines: [OcrLine], toleranceRatio: CGFloat) -> [[OcrLine]] {
        let sorted = lines.sorted { a, b in
            if abs(a.box.minY - b.box.minY) > 1e-9 { return a.box.minY > b.box.minY }
            return a.box.minX < b.box.minX
        }
        var rows: [[OcrLine]] = []
        for line in sorted {
            if let index = rows.firstIndex(where: { row in
                let box = unionBox(row)
                let tolerance = toleranceRatio * Swift.max(box.height, line.box.height)
                return abs(line.box.minY - box.minY) <= tolerance
            }) {
                rows[index].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    static func horizontalParagraphs(_ rows: [[OcrLine]], config: OcrLayoutConfig) -> [OcrParagraph] {
        var groups: [[[OcrLine]]] = []
        for row in rows where !row.isEmpty {
            if let previousGroup = groups.last, let previousRow = previousGroup.last,
               shouldMerge(previousRow, row, config: config) {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups.map { group in
            let text = group.map(rowText).reduce("") { joinSoftWrap($0, $1) }
            return OcrParagraph(text: text, lines: group.flatMap { $0 }, isVertical: false)
        }
    }

    /// 行距在阈值内、且横向有重叠或中心接近 → 同一段落（文档 §6.3 行间距阈值拼接）。
    static func shouldMerge(_ previous: [OcrLine], _ next: [OcrLine], config: OcrLayoutConfig) -> Bool {
        let top = unionBox(previous)
        let bottom = unionBox(next)
        let gap = top.minY - bottom.maxY
        guard gap <= config.paragraphGapRatio * Swift.max(top.height, bottom.height) else { return false }
        let overlap = Swift.min(top.maxX, bottom.maxX) - Swift.max(top.minX, bottom.minX)
        if overlap > 0 { return true }
        return abs(top.midX - bottom.midX) <= 0.5 * Swift.max(top.width, bottom.width)
    }

    /// 同一行内多个识别片段拼接：横向空隙明显，或两侧都不是全角字符时补一个空格。
    static func rowText(_ row: [OcrLine]) -> String {
        var result = ""
        var previous: OcrLine?
        for line in row {
            let piece = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let previous {
                let gap = line.box.minX - previous.box.maxX
                let height = Swift.max(previous.box.height, line.box.height)
                let wideBoundary = isWide(previous.text.last) || isWide(piece.first)
                let needsSpace = gap > 0.35 * height || !wideBoundary
                if needsSpace { result += " " }
            }
            result += piece
            previous = line
        }
        return result
    }

    /// 折行拼接：全角字符相邻不插空格，否则按西文习惯补空格。全角标点原样保留（不转半角）。
    static func joinSoftWrap(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        if isWide(head.last) || isWide(tail.first) { return head + tail }
        return head + " " + tail
    }

    // MARK: - 竖排

    static func verticalLayout(_ lines: [OcrLine], config: OcrLayoutConfig) -> OcrLayout {
        // 同一竖排文本列 = x 区间明显重叠；列顺序右→左。
        let ordered = lines.sorted { $0.box.maxX > $1.box.maxX }
        var columns: [[OcrLine]] = []
        for line in ordered {
            if let index = columns.firstIndex(where: { column in
                let box = unionBox(column)
                let overlap = Swift.min(box.maxX, line.box.maxX) - Swift.max(box.minX, line.box.minX)
                return overlap > 0.4 * Swift.min(box.width, line.box.width)
            }) {
                columns[index].append(line)
            } else {
                columns.append([line])
            }
        }
        let paragraphs = columns.map { column -> OcrParagraph in
            let topToBottom = column.sorted { $0.box.minY > $1.box.minY }
            let text = topToBottom
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined()
            return OcrParagraph(text: text, lines: topToBottom, isVertical: true)
        }
        return OcrLayout(paragraphs: paragraphs, readingOrder: paragraphs.flatMap(\.lines), isVertical: true)
    }

    // MARK: - 工具

    static func unionBox(_ lines: [OcrLine]) -> CGRect {
        guard var box = lines.first?.box else { return .zero }
        for line in lines.dropFirst() { box = box.union(line.box) }
        return box
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// 全角/宽字符（CJK 表意文字、假名、谚文、全角标点），用于判断拼接是否需要空格。
    static func isWide(_ character: Character?) -> Bool {
        guard let character, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
