import Foundation
import Contracts

/// Stage2 的 JSON 容错（文档 R6：严格校验 + 一次重试 + 失败只降级细节）。
public enum TranslationJSON {
    /// 从模型返回里抠出第一个完整 JSON 对象（容忍代码块围栏与前后解释文字）。
    public static func extractObject(from content: String) -> String? {
        let characters = Array(content)
        guard let start = characters.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(characters[start...index])
                    }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    /// 解码细节；不合格（空对象 / 无 translation 且无任何词条）返回 nil，由调用方重试或降级。
    public static func detail(
        from content: String,
        fallbackTranslation: String?,
        request: TranslateRequest
    ) -> TranslationDetail? {
        guard let json = extractObject(from: content), let data = json.data(using: .utf8) else { return nil }
        guard var detail = try? JSONDecoder().decode(TranslationDetail.self, from: data) else {
            guard let repaired = repair(json), let repairedData = repaired.data(using: .utf8) else { return nil }
            guard var candidate = try? JSONDecoder().decode(TranslationDetail.self, from: repairedData) else {
                return nil
            }
            candidate.targetLang = request.pair.target
            return validated(candidate, fallbackTranslation: fallbackTranslation)
        }
        detail.targetLang = request.pair.target
        return validated(detail, fallbackTranslation: fallbackTranslation)
    }

    private static func validated(_ detail: TranslationDetail, fallbackTranslation: String?) -> TranslationDetail? {
        var result = detail
        if result.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.translation = fallbackTranslation ?? ""
        }
        let isEmpty = result.translation.isEmpty
            && result.senses.isEmpty
            && result.synonyms.isEmpty
            && result.usage.isEmpty
            && result.notes.isEmpty
        return isEmpty ? nil : result
    }

    /// 轻度修复：把非字符串的 translation、缺失的数组字段归一，再交回 Codable。
    public static func repair(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let number = object["translation"] as? NSNumber {
            object["translation"] = number.stringValue
        }
        for key in ["senses", "synonyms", "usage", "notes"] where object[key] == nil {
            object[key] = []
        }
        if object["notes"] != nil, object["notes"] is String {
            object["notes"] = [object["notes"] as? String ?? ""]
        }
        guard let repaired = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: repaired, encoding: .utf8)
    }
}
