import Foundation

/// 日志与错误脱敏（文档 §6.7 末段：日志与错误提示永不回显 apiKey）。
public enum Redaction {
    public static let placeholder = "<redacted>"

    /// 把文本里出现的密钥替换掉。短于 6 字符的密钥不足以单独鉴别，替换会误伤正文，故跳过。
    public static func scrub(_ text: String, secrets: [String]) -> String {
        var out = text
        for secret in secrets where secret.count >= 6 {
            out = out.replacingOccurrences(of: secret, with: placeholder)
        }
        return scrubPatterns(out)
    }

    /// 兜底：形如 "sk-xxxx" 或 "Bearer xxxx" 的残留一律抹掉。
    static func scrubPatterns(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(sk-|Bearer[ \t]+)[A-Za-z0-9_\\-]{6,}") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: placeholder)
    }
}
