import Foundation
import CoreGraphics
import Vision
import Contracts

/// OCR 选项。recognitionLanguages 可配置，默认中/英/日/韩（文档 §6.3）。
public struct OcrOptions: Sendable {
    public static let defaultRecognitionLanguages = ["zh-Hans", "en-US", "ja-JP", "ko-KR"]

    public var recognitionLanguages: [String]
    public var recognitionLevel: VNRequestTextRecognitionLevel
    public var usesLanguageCorrection: Bool
    public var customWords: [String]
    public var automaticallyDetectsLanguage: Bool
    public var layout: OcrLayoutConfig

    public init(recognitionLanguages: [String] = OcrOptions.defaultRecognitionLanguages,
                recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
                usesLanguageCorrection: Bool = true,
                customWords: [String] = [],
                automaticallyDetectsLanguage: Bool = false,
                layout: OcrLayoutConfig = OcrLayoutConfig()) {
        self.recognitionLanguages = recognitionLanguages
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.customWords = customWords
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        self.layout = layout
    }
}

/// 识别结果 + 版面聚合（text 为段落拼接后的可翻译文本）。
public struct OcrRecognition: Sendable, Hashable {
    public let result: OcrResult
    public let layout: OcrLayout

    public init(result: OcrResult, layout: OcrLayout) {
        self.result = result
        self.layout = layout
    }

    /// 段落合并文本；版面为空时退回逐行文本。
    public var text: String {
        let merged = layout.text
        return merged.isEmpty ? result.joinedText : merged
    }
}

/// VNRecognizeTextRequest 封装：.accurate + 语言校正，行框取 observation.boundingBox（归一化、左下原点）。
public enum VisionTextRecognizer {

    /// 所有 Vision 请求（预热 + 正式识别）共用一条串行队列：
    /// 并发调用 VNImageRequestHandler 在冷启动阶段会互相卡住，串行后至少是「排队」而不是死锁。
    public static let serialQueue = DispatchQueue(
        label: "com.local.translationreader.ocr.vision",
        qos: .userInitiated
    )

    public static func recognize(image: CGImage, options: OcrOptions = OcrOptions()) async throws -> OcrRecognition {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OcrRecognition, Error>) in
            serialQueue.async {
                do {
                    continuation.resume(returning: try recognizeSync(image: image, options: options))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func recognizeSync(image: CGImage, options: OcrOptions) throws -> OcrRecognition {
        let started = DispatchTime.now()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.recognitionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.recognitionLanguages = sanitizedLanguages(options.recognitionLanguages, level: options.recognitionLevel)
        if !options.customWords.isEmpty {
            request.customWords = options.customWords
        }
        if options.automaticallyDetectsLanguage {
            request.automaticallyDetectsLanguage = true
        }
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw AppError.unknown(message: "文字识别失败：\(error.localizedDescription)")
        }

        let observations = request.results ?? []
        var lines: [OcrLine] = []
        lines.reserveCapacity(observations.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(OcrLine(text: candidate.string,
                                 confidence: candidate.confidence,
                                 box: observation.boundingBox))
        }

        let layout = OcrPostProcessor.layout(lines, config: options.layout)
        let plainText = layout.text.isEmpty
            ? lines.map(\.text).joined(separator: "\n")
            : layout.text
        let guess = OcrLanguageDetector.detect(text: plainText, candidates: options.recognitionLanguages)

        let elapsed = Int(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000
        let ordered = layout.readingOrder.isEmpty ? lines : layout.readingOrder
        let result = OcrResult(lines: ordered, detectedLanguage: guess.code, elapsedMs: elapsed)
        return OcrRecognition(result: result, layout: layout)
    }

    /// 过滤掉当前系统不支持的语种代码，避免 VNRequest 直接抛错。
    static func sanitizedLanguages(_ languages: [String], level: VNRequestTextRecognitionLevel) -> [String] {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = level
        if #available(macOS 13.0, *) { probe.revision = VNRecognizeTextRequestRevision3 }
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        guard !supported.isEmpty else { return languages.isEmpty ? OcrOptions.defaultRecognitionLanguages : languages }
        let filtered = languages.filter { supported.contains($0) }
        return filtered.isEmpty ? supported.prefix(2).map { $0 } : filtered
    }
}
