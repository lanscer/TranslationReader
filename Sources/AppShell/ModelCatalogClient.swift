import Foundation
import Contracts
import TranslateKit

/// 模型列表拉取与失败诊断（CT 2026-10-30：多数网关要求厂商前缀，手写裸名直接 400）。
/// 走 OpenAI 兼容的 GET {baseURL}/models，响应支持三种常见形状：
///   - {"data":[{"id":"deepseek/deepseek-v4.1-flash"}]}
///   - {"models":[{"name":"..."}]}
///   - ["a","b"] / {"data":["a","b"]}
enum ModelCatalogError: Error, Equatable {
    case invalidBaseURL
    case http(status: Int, body: String, endpoint: String)
    case transport(String)
    case empty(String)

    /// 面向用户的文案：与 TranslateKit 的错误口径一致（401 鉴权 / 404 端点 / 其余报网关原文）。
    var userMessage: String {
        switch self {
        case .invalidBaseURL:
            return "baseURL 无法解析（应形如 https://host/v1）"
        case .http(let status, let body, _):
            switch status {
            case 401, 403:
                return "鉴权失败（HTTP \(status)）：API Key 无效或无权限"
            case 404:
                return "端点不存在（HTTP 404）：检查 baseURL 是否多了/少了 /v1"
            default:
                return "HTTP \(status)：「\(Self.preview(body))」"
            }
        case .transport(let message):
            return "网络错误：\(message)"
        case .empty(let raw):
            return "响应里没有模型列表：「\(Self.preview(raw))」"
        }
    }

    /// 完整诊断行：可整段复制给客服/同事，绝不含 apiKey。
    func diagnostic(baseURL: String, modelName: String?) -> String {
        var parts = ["baseURL=\(baseURL)"]
        if let modelName, !modelName.isEmpty { parts.append("模型=\(modelName)") }
        switch self {
        case .invalidBaseURL:
            parts.append("错误=baseURL 无法解析")
        case .http(let status, let body, let endpoint):
            parts.append("endpoint=\(endpoint)")
            parts.append("HTTP \(status)")
            parts.append("网关原文=\(Self.preview(body, limit: 1200))")
        case .transport(let message):
            parts.append("错误=\(message)")
        case .empty(let raw):
            parts.append("网关原文=\(Self.preview(raw, limit: 800))")
        }
        return parts.joined(separator: " | ")
    }

    static func preview(_ body: String, limit: Int = 400) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…(共 \(trimmed.count) 字符)"
    }
}

struct ModelCatalogResult: Equatable {
    let models: [String]
    let endpoint: String
    let elapsedMs: Int
}

enum ModelCatalogClient {
    /// GET {baseURL}/models。baseURL 若被写成 .../chat/completions 也能自动回退到根。
    static func modelsURL(baseURL: String) -> URL? {
        // 归一化交给 TranslateKit（已覆盖 /provider/v1、尾斜杠、已含 /chat/completions 四种形态）。
        guard let apiBase = OpenAITranslateProvider.apiBaseURL(baseURL: baseURL) else { return nil }
        var path = apiBase.absoluteString
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/models") { path += "/models" }
        guard let url = URL(string: path), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    static func fetch(baseURL: String, apiKey: String?) async -> Result<ModelCatalogResult, ModelCatalogError> {
        guard let url = modelsURL(baseURL: baseURL) else { return .failure(.invalidBaseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let started = DispatchTime.now()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            let body = String(decoding: data, as: UTF8.self)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.http(status: http.statusCode, body: body, endpoint: url.absoluteString))
            }
            let models = parseModels(from: data)
            guard !models.isEmpty else { return .failure(.empty(body)) }
            return .success(ModelCatalogResult(models: models, endpoint: url.absoluteString, elapsedMs: elapsed))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// 兼容 data[].id / models[].name / 纯字符串数组；排序去重，保留厂商前缀原文。
    static func parseModels(from data: Data) -> [String] {
        var found: [String] = []
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let array = object as? [Any] {
                found = ids(in: array)
            } else if let dict = object as? [String: Any] {
                if let array = dict["data"] as? [Any] {
                    found = ids(in: array)
                } else if let array = dict["models"] as? [Any] {
                    found = ids(in: array)
                }
            }
        }
        var seen = Set<String>()
        return found
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
    }

    private static func ids(in array: [Any]) -> [String] {
        array.compactMap { element in
            if let text = element as? String { return text }
            if let dict = element as? [String: Any] {
                return dict["id"] as? String ?? dict["name"] as? String ?? dict["model"] as? String
            }
            return nil
        }
    }
}
