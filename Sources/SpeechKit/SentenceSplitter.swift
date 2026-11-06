import Foundation

/// 中英日混排分句（文档 §6.6「分句：正则切句 → 队列（≤3 句预取）→ 顺序合成」）。
///
/// 规则：句末标点收句，闭合引号/括号跟随句末归属前句；换行视为硬断句；
/// 超长句在逗号/顿号/空格处软断，避免单句合成阻塞预取队列。
public enum SentenceSplitter {
    /// 句末标点。中英日全半角都算。
    private static let terminators: Set<Character> = [
        "。", "！", "？", "；", "…", "!", "?", ";", ".",
    ]
    /// 收句后仍归属本句的闭合符号。
    private static let closers: Set<Character> = [
        "”", "’", "」", "』", "）", ")", "】", "》", "\"", "'", "]", "}",
    ]
    /// 常见英文缩写：点后面紧跟大写词也不收句。
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "jr", "sr", "no", "vol", "fig", "approx",
    ]
    /// 软断点：超长句优先在此切开。
    private static let softBreaks: Set<Character> = ["，", ",", "、", "：", ":", " ", "—"]

    /// 切句。返回已 trim、非空的句子数组。
    /// - Parameters:
    ///   - text: 原文，允许中英日混排与任意空白。
    ///   - maxLength: 单句字符上限，超限时软断。
    public static func split(_ text: String, maxLength: Int = 200) -> [String] {
        guard maxLength > 0 else { return [] }
        let chars = Array(text)
        var sentences: [String] = []
        var buffer = ""
        var index = 0

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            buffer = ""
        }

        while index < chars.count {
            let char = chars[index]

            if char == "\n" {
                flush()
                index += 1
                continue
            }

            buffer.append(char)

            if terminators.contains(char), isTerminator(chars, at: index) {
                var cursor = index + 1
                while cursor < chars.count, closers.contains(chars[cursor]) {
                    buffer.append(chars[cursor])
                    cursor += 1
                }
                index = cursor
                flush()
                continue
            }

            if buffer.count >= maxLength {
                if let cut = softCutPoint(in: buffer) {
                    let head = String(buffer.prefix(cut))
                    buffer = String(buffer.dropFirst(cut))
                    let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { sentences.append(trimmed) }
                } else {
                    flush()
                }
            }
            index += 1
        }

        flush()
        return sentences
    }

    /// 该位置是否真的收句：小数点、连续省略号、紧邻字母的缩写点都不算。
    private static func isTerminator(_ chars: [Character], at index: Int) -> Bool {
        let char = chars[index]
        let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
        let previous: Character? = index > 0 ? chars[index - 1] : nil

        if let next, terminators.contains(next) { return false }

        switch char {
        case ".":
            if let previous, previous.isNumber, let next, next.isNumber { return false }
            if let next, next.isLetter { return false }
            var cursor = index - 1
            var word = ""
            while cursor >= 0, chars[cursor].isLetter {
                word = String(chars[cursor]) + word
                cursor -= 1
            }
            if abbreviations.contains(word.lowercased()) { return false }
            return true
        default:
            return true
        }
    }

    /// 超长句的软断点：在后半段里从后往前找软断符；找不到返回 nil（调用方硬切）。
    private static func softCutPoint(in buffer: String) -> Int? {
        let chars = Array(buffer)
        guard chars.count >= 2 else { return nil }
        let lowerBound = max(1, chars.count / 2)
        var cursor = chars.count - 1
        while cursor >= lowerBound {
            if softBreaks.contains(chars[cursor]) { return cursor + 1 }
            cursor -= 1
        }
        return nil
    }
}
