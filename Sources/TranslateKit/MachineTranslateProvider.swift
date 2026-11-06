import Foundation
import Contracts

// MachineTranslateProvider：免密钥的机器翻译 Provider（默认引擎）。
//
// 支持三家公开接口，全部不需要 apiKey：
//   · 有道（aidemo.youdao.com/trans）—— 国内直连，最快，默认首选
//   · MyMemory（api.mymemory.translated.net/get）—— 免费额度，全球可用
//   · 谷歌（translate.googleapis.com/translate_a/single，gtx 客户端）—— 海外网络
//
// 与 AI Provider 的差异：非流式（一次性拿全文）、只有译文、没有词条细节。
// 事件序列固定为「一个 .delta(全文) + finish」，卡片仍按流式逻辑消费，不需要特判。

/// 机器翻译内部错误：保留服务商与状态码，最终聚合成一条用户可读文案。
struct MachineTranslationFailure: Error, Equatable {
    let service: MachineTranslationService
    let status: Int?
    let detail: String
}

// MARK: - 语言码映射

enum MachineTranslationLanguage {
    static func detect(_ text: String) -> LangCode {
        var han = 0, kana = 0, hangul = 0, cyrillic = 0, arabic = 0, thai = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF: hangul += 1
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0600...0x06FF: arabic += 1
            case 0x0E00...0x0E7F: thai += 1
            case 0x0041...0x005A, 0x0061...0x007A: latin += 1
            default: break
            }
        }
        if kana > 0 { return .ja }
        if hangul > 0 { return .ko }
        if han > 0 && han >= latin { return .zhHans }
        if cyrillic > 0 { return .ru }
        if arabic > 0 { return .ar }
        if thai > 0 { return .th }
        return .en
    }

    /// 有道 / 智云的语言码。
    static func youdao(_ code: LangCode) -> String {
        switch code {
        case .auto: return "auto"
        case .zhHans: return "zh-CHS"
        case .zhHant: return "zh-CHT"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        case .ru: return "ru"
        case .pt: return "pt"
        case .es: return "es"
        case .it: return "it"
        case .ar: return "ar"
        case .th: return "th"
        case .vi: return "vi"
        }
    }

    /// 谷歌翻译的 BCP-47 变体。
    static func google(_ code: LangCode) -> String {
        switch code {
        case .auto: return "auto"
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        case .ru: return "ru"
        case .pt: return "pt"
        case .es: return "es"
        case .it: return "it"
        case .ar: return "ar"
        case .th: return "th"
        case .vi: return "vi"
        }
    }

    /// MyMemory 的 langpair 语言码（不支持 auto，调用前先本地猜）。
    static func myMemory(_ code: LangCode) -> String {
        switch code {
        case .auto, .en: return "en"
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        case .ru: return "ru"
        case .pt: return "pt"
        case .es: return "es"
        case .it: return "it"
        case .ar: return "ar"
        case .th: return "th"
        case .vi: return "vi"
        }
    }
}

// MARK: - 长文本分块

enum MachineTranslationText {
    /// 按 UTF-8 字节上限切块：优先在句末标点处断开，超长单句再按字符硬切。
    static func chunks(_ text: String, maxBytes: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.utf8.count > maxBytes, maxBytes > 0 else { return [trimmed] }

        var result: [String] = []
        var current = ""

        func flush() {
            let piece = current
            current = ""
            if !piece.isEmpty { result.append(piece) }
        }

        for unit in sentenceUnits(trimmed) {
            if current.utf8.count + unit.utf8.count <= maxBytes {
                current += unit
                continue
            }
            flush()
            if unit.utf8.count <= maxBytes {
                current = unit
                continue
            }
            var buffer = ""
            for character in unit {
                let candidate = buffer + String(character)
                if candidate.utf8.count > maxBytes {
                    result.append(buffer)
                    buffer = String(character)
                } else {
                    buffer = candidate
                }
            }
            current = buffer
        }
        flush()
        return result
    }

    /// 句末标点后切一刀（保留标点与换行）。
    static func sentenceUnits(_ text: String) -> [String] {
        var units: [String] = []
        var buffer = ""
        let separators: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "\n"]
        for character in text {
            buffer.append(character)
            if separators.contains(character) {
                units.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { units.append(buffer) }
        return units
    }
}

// MARK: - 请求构造

enum MachineTranslationRequests {
    static let youdaoEndpoint = URL(string: "https://aidemo.youdao.com/trans")!
    static let myMemoryEndpoint = URL(string: "https://api.mymemory.translated.net/get")!
    static let googleEndpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!

    static func request(
        service: MachineTranslationService,
        text: String,
        pair: LanguagePair,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request: URLRequest
        switch service {
        case .auto:
            throw MachineTranslationFailure(service: .auto, status: nil, detail: "自动模式不应直接构造请求")
        case .youdao:
            request = URLRequest(url: youdaoEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let from = MachineTranslationLanguage.youdao(pair.source)
            let to = MachineTranslationLanguage.youdao(pair.target == .auto ? .zhHans : pair.target)
            let body = "q=" + formEncode(text) + "&from=" + from + "&to=" + to
            request.httpBody = Data(body.utf8)
        case .myMemory:
            let source = pair.source == .auto ? MachineTranslationLanguage.detect(text) : pair.source
            let target = pair.target == .auto ? .zhHans : pair.target
            var components = URLComponents(url: myMemoryEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "q", value: text),
                URLQueryItem(
                    name: "langpair",
                    value: MachineTranslationLanguage.myMemory(source) + "|" + MachineTranslationLanguage.myMemory(target)
                ),
            ]
            guard let url = components.url else {
                throw MachineTranslationFailure(service: .myMemory, status: nil, detail: "请求 URL 构造失败")
            }
            request = URLRequest(url: url)
            request.httpMethod = "GET"
        case .google:
            var components = URLComponents(url: googleEndpoint, resolvingAgainstBaseURL: false)!
            let target = pair.target == .auto ? .zhHans : pair.target
            components.queryItems = [
                URLQueryItem(name: "client", value: "gtx"),
                URLQueryItem(name: "sl", value: MachineTranslationLanguage.google(pair.source)),
                URLQueryItem(name: "tl", value: MachineTranslationLanguage.google(target)),
                URLQueryItem(name: "dt", value: "t"),
                URLQueryItem(name: "q", value: text),
            ]
            guard let url = components.url else {
                throw MachineTranslationFailure(service: .google, status: nil, detail: "请求 URL 构造失败")
            }
            request = URLRequest(url: url)
            request.httpMethod = "GET"
        }
        request.timeoutInterval = timeout
        // 公开接口不接受自定义 UA 之外的伪装；保持默认即可，这里只加接受类型。
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// 表单编码：只保留 RFC 3986 unreserved 字符，空格编码为 %20。
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - 响应解析

enum MachineTranslationParser {
    static func parse(service: MachineTranslationService, data: Data) throws -> String {
        switch service {
        case .youdao: return try youdao(data)
        case .myMemory: return try myMemory(data)
        case .google: return try google(data)
        case .auto: throw MachineTranslationFailure(service: .auto, status: nil, detail: "自动模式不应直接解析响应")
        }
    }

    static func youdao(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MachineTranslationFailure(service: .youdao, status: nil, detail: "返回不是 JSON 对象")
        }
        let code: String
        if let text = object["errorCode"] as? String {
            code = text
        } else if let number = object["errorCode"] as? NSNumber {
            code = number.stringValue
        } else {
            code = "0"
        }
        guard code == "0" else {
            throw MachineTranslationFailure(service: .youdao, status: nil, detail: "错误码 \(code)")
        }
        guard let fragments = object["translation"] as? [String] else {
            throw MachineTranslationFailure(service: .youdao, status: nil, detail: "缺少 translation 字段")
        }
        let text = fragments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MachineTranslationFailure(service: .youdao, status: nil, detail: "译文为空")
        }
        return text
    }

    static func google(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any]
        else {
            throw MachineTranslationFailure(service: .google, status: nil, detail: "返回结构不是预期的数组")
        }
        var output = ""
        for segment in segments {
            guard let parts = segment as? [Any], let first = parts.first as? String else { continue }
            output += first
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MachineTranslationFailure(service: .google, status: nil, detail: "译文为空")
        }
        return text
    }

    static func myMemory(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MachineTranslationFailure(service: .myMemory, status: nil, detail: "返回不是 JSON 对象")
        }
        let status: Int
        if let number = object["responseStatus"] as? NSNumber {
            status = number.intValue
        } else if let text = object["responseStatus"] as? String, let value = Int(text) {
            status = value
        } else {
            status = 200
        }
        let details = (object["responseDetails"] as? String) ?? ""
        guard status == 200 else {
            throw MachineTranslationFailure(
                service: .myMemory,
                status: status,
                detail: details.isEmpty ? "配额或参数错误" : details
            )
        }
        guard let payload = object["responseData"] as? [String: Any],
              let raw = payload["translatedText"] as? String
        else {
            throw MachineTranslationFailure(service: .myMemory, status: status, detail: details.isEmpty ? "缺少译文字段" : details)
        }
        let text = unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MachineTranslationFailure(service: .myMemory, status: status, detail: "译文为空")
        }
        // 免费额度用尽时接口仍返回 200，正文里带 MYMEMORY WARNING。
        if text.contains("MYMEMORY WARNING") || text.contains("QUERY LENGTH LIMIT") {
            throw MachineTranslationFailure(service: .myMemory, status: status, detail: text)
        }
        return text
    }

    /// MyMemory 偶发返回 HTML 实体（机器语料里带引号）。
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let mapping = [
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&lt;": "<", "&gt;": ">", "&amp;": "&",
        ]
        for (entity, value) in mapping {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}

// MARK: - Provider

public final class MachineTranslateProvider: TranslateProvider, @unchecked Sendable {
    /// 错误体只取前 8KB，避免异常响应撑爆内存。
    static let maxErrorBodyBytes = 8 * 1024

    public let settings: AppSettings.Translate
    public let cache: TranslateCache
    /// 本次请求实际尝试的顺序。
    public let services: [MachineTranslationService]

    private let transport: HTTPTransport
    private let policy: RequestPolicy

    public init(
        settings: AppSettings.Translate,
        transport: HTTPTransport? = nil,
        cache: TranslateCache = TranslateCache(),
        policy: RequestPolicy? = nil
    ) {
        self.settings = settings
        self.cache = cache
        let chain = settings.machineService.fallbackChain
        self.services = chain.isEmpty ? [.youdao] : chain

        let total = max(3, Double(settings.machineTimeoutMs) / 1000)
        let resolved = policy ?? RequestPolicy(
            connectTimeout: min(4, total),
            totalTimeout: total,
            retryBackoff: 0.3,
            maxRetries: 0
        )
        self.policy = resolved
        self.transport = transport ?? URLSessionTransport(policy: resolved)
    }

    // MARK: TranslateProvider

    public func translate(_ request: TranslateRequest) -> AsyncThrowingStream<TranslateEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { await self.run(request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: TranslateRequest,
        continuation: AsyncThrowingStream<TranslateEvent, Error>.Continuation
    ) async {
        do {
            let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continuation.finish(throwing: AppError.invalidResponse(reason: "待翻译文本为空"))
                return
            }

            if let hit = await cache.value(for: request, engine: .machine) {
                continuation.yield(.delta(hit.translation))
                continuation.finish()
                return
            }

            var failures: [String] = []
            for service in services {
                try Task.checkCancellation()
                do {
                    let translated = try await translate(text: text, pair: request.pair, service: service)
                    await cache.store(request, engine: .machine, translation: translated, detail: nil)
                    continuation.yield(.delta(translated))
                    continuation.finish()
                    return
                } catch is CancellationError {
                    continuation.finish(throwing: AppError.cancelled)
                    return
                } catch {
                    failures.append(service.cardName + "：" + describe(error))
                }
            }

            let summary = failures.joined(separator: "；")
            let message = settings.machineService == .auto
                ? "机器翻译失败（\(summary)）。可点「重试」，或在卡片顶栏切到 AI 翻译。"
                : "机器翻译失败（\(settings.machineService.displayName)：\(summary)）。可点「重试」，或在卡片顶栏切到 AI 翻译。"
            continuation.finish(throwing: AppError.unknown(message: message))
        } catch is CancellationError {
            continuation.finish(throwing: AppError.cancelled)
        } catch {
            continuation.finish(throwing: AppError.unknown(message: describe(error)))
        }
    }

    // MARK: 单服务请求

    private func translate(
        text: String,
        pair: LanguagePair,
        service: MachineTranslationService
    ) async throws -> String {
        let pieces = MachineTranslationText.chunks(text, maxBytes: service.requestByteLimit)
        guard !pieces.isEmpty else {
            throw MachineTranslationFailure(service: service, status: nil, detail: "待翻译文本为空")
        }
        var parts: [String] = []
        for piece in pieces {
            try Task.checkCancellation()
            parts.append(try await requestOnce(piece, pair: pair, service: service))
        }
        return parts.joined(separator: "\n")
    }

    private func requestOnce(
        _ text: String,
        pair: LanguagePair,
        service: MachineTranslationService
    ) async throws -> String {
        let urlRequest = try MachineTranslationRequests.request(
            service: service,
            text: text,
            pair: pair,
            timeout: policy.totalTimeout
        )
        var body = Data()
        var head: HTTPResponseHead?

        do {
            for try await event in transport.stream(urlRequest) {
                switch event {
                case .head(let value):
                    head = value
                case .body(let data):
                    if body.count < Self.maxErrorBodyBytes * 4 { body.append(data) }
                }
            }
        } catch let error as AppError {
            throw error
        } catch let failure as MachineTranslationFailure {
            throw failure
        } catch let error as TransportError {
            switch error {
            case .timedOut(let seconds): throw AppError.timeout(seconds: seconds)
            case .cancelled: throw CancellationError()
            }
        } catch {
            throw AppError.network(underlying: error.localizedDescription)
        }

        guard let head else {
            throw MachineTranslationFailure(service: service, status: nil, detail: "未收到响应头")
        }
        guard (200..<300).contains(head.statusCode) else {
            throw MachineTranslationFailure(
                service: service,
                status: head.statusCode,
                detail: Self.shortBody(body)
            )
        }
        return try MachineTranslationParser.parse(service: service, data: body)
    }

    // MARK: 诊断文案

    private func describe(_ error: Error) -> String {
        switch error {
        case let failure as MachineTranslationFailure:
            if let status = failure.status {
                return "HTTP \(status)" + (failure.detail.isEmpty ? "" : " · " + Self.collapse(failure.detail))
            }
            return Self.collapse(failure.detail)
        case let appError as AppError:
            return appError.userMessage
        case let transportError as TransportError:
            if case .timedOut(let seconds) = transportError { return "超时（\(Int(seconds))s）" }
            return "已取消"
        default:
            return Self.collapse(error.localizedDescription)
        }
    }

    static func collapse(_ text: String, limit: Int = 120) -> String {
        let flattened = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// 非 2xx 时的错误体：优先取 JSON 里的 message，否则截断纯文本。
    static func shortBody(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty { return message }
            if let details = object["responseDetails"] as? String, !details.isEmpty { return details }
        }
        let text = String(decoding: data.prefix(512), as: UTF8.self)
        return collapse(text)
    }
}
