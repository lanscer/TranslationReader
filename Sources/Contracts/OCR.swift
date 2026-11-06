import Foundation
import CoreGraphics

/// 文档 §6.3 冻结的 OCR 行。
public struct OcrLine: Codable, Hashable, Sendable {
    public let text: String
    public let confidence: Float
    /// Vision 归一化坐标系（0...1，左下原点）。
    public let box: CGRect

    public init(text: String, confidence: Float, box: CGRect) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

/// 文档 §6.3 冻结的 OCR 结果。
public struct OcrResult: Codable, Hashable, Sendable {
    public let lines: [OcrLine]
    public let detectedLanguage: String?
    public let elapsedMs: Int

    public init(lines: [OcrLine], detectedLanguage: String? = nil, elapsedMs: Int = 0) {
        self.lines = lines
        self.detectedLanguage = detectedLanguage
        self.elapsedMs = elapsedMs
    }

    /// 按行拼接（保留换行结构，文档 §6.3 / §6.5 Prompt 约束 2）。
    public var joinedText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}
