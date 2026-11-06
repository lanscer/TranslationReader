import Foundation
import CoreGraphics
import Vision
import Contracts

/// 截图 OCR 的 Vision 层门面（文档 §6.3）。实现在 OcrPostProcessor / VisionTextRecognizer / OcrLanguageDetector。
public enum OCRVision {
    public static let moduleName = "OCRVision"

    public static let defaultRecognitionLanguages = OcrOptions.defaultRecognitionLanguages
    public static let lowLanguageConfidenceThreshold = OcrLanguageDetector.lowConfidenceThreshold

    /// ContractVisibility 探针需要的空结果（T1 冻结的调用点）。
    public static func recognizeStub() -> OcrResult {
        OcrResult(lines: [], detectedLanguage: nil, elapsedMs: 0)
    }

    /// 识别 + 行聚合，返回契约结果（lines 已按阅读顺序重排，elapsedMs 为识别耗时）。
    public static func recognize(image: CGImage, options: OcrOptions = OcrOptions()) async throws -> OcrResult {
        try await recognizeLayout(image: image, options: options).result
    }

    /// 同一次识别同时给出契约结果与版面（段落文本 = OcrRecognition.text）。
    public static func recognizeLayout(image: CGImage, options: OcrOptions = OcrOptions()) async throws -> OcrRecognition {
        guard image.width > 0, image.height > 0 else {
            throw AppError.unknown(message: "截图内容为空，无法识别。")
        }
        return try await VisionTextRecognizer.recognize(image: image, options: options)
    }

    /// 带硬超时的识别：Vision 的 `perform` 在少数图像/系统状态下会长时间不返回，
    /// 调用方不能无限等（截图链路会整条卡死）。到点先抛超时，工作线程留在后台自行结束。
    public static func recognizeWithTimeout(
        image: CGImage,
        options: OcrOptions = OcrOptions(),
        timeout: TimeInterval = 12
    ) async throws -> OcrResult {
        guard image.width > 0, image.height > 0 else {
            throw AppError.unknown(message: "截图内容为空，无法识别。")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = RaceGate()
            func finish(_ result: Result<OcrResult, Error>) {
                guard gate.tryFinish() else { return }
                continuation.resume(with: result)
            }
            Task.detached(priority: .userInitiated) {
                do {
                    finish(.success(try await recognize(image: image, options: options)))
                } catch {
                    finish(.failure(error))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                finish(.failure(AppError.unknown(
                    message: "文字识别超时（\(Int(timeout))s）：换一块区域重试，或稍后再试。"
                )))
            }
        }
    }

    /// 纯文本入口：OCR → 段落合并文本。
    public static func recognizeText(image: CGImage, options: OcrOptions = OcrOptions()) async throws -> String {
        try await recognizeLayout(image: image, options: options).text
    }

    /// 预热：第一次 VNRecognizeTextRequest 会加载 Vision 文字识别模型，本机实测首次调用 29.9s
    /// （2560×1440），之后单次 430~480ms。若等到用户按 ⌥S 才第一次调用，界面会「卡住 30 秒」。
    ///
    /// 调用时机（由 T6 在 AppShell 里接）：App 启动完成、首帧 UI 出现之后调用一次，
    /// 不要在热键回调/截图回调里调用；建议放到 background 优先级，不阻塞启动。
    /// 例：Task.detached(priority: .background) { await OCRVision.prewarm() }
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var _prewarmFinished = false
    private nonisolated(unsafe) static var _prewarmMs: Int?

    /// 预热是否已完成（冷启动模型加载本机实测约 30s；没完成时截图链路要放宽超时）。
    public static var isPrewarmed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _prewarmFinished
    }

    /// 预热耗时（毫秒），未完成时为 nil。
    public static var prewarmMilliseconds: Int? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _prewarmMs
    }

    public static func prewarm() async {
        _ = await warmUp()
    }

    /// 预热并返回耗时。带 App Nap 抑制：后台低优先级任务被系统挂起时，
    /// Vision 的全局模型加载会一直占着锁，后面的正式识别就永远等不到。
    @discardableResult
    public static func warmUp() async -> Int {
        let started = DispatchTime.now()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Vision OCR 预热"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let image: CGImage? = {
            guard let context = CGContext(data: nil,
                                          width: 8,
                                          height: 8,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 8 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            VisionTextRecognizer.serialQueue.async {
                defer { continuation.resume() }
                guard let image else { return }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = OcrOptions.defaultRecognitionLanguages
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([request])
            }
        }

        let ms = Int(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000
        stateLock.lock()
        _prewarmFinished = true
        _prewarmMs = ms
        stateLock.unlock()
        return ms
    }

    /// 后台预热（不等待）：启动阶段直接调用即可。
    public static func prewarmInBackground() {
        Task.detached(priority: .background) { await prewarm() }
    }
}

/// 只允许第一个结果通过（识别完成 vs 超时，二者只能有一个生效）。
private final class RaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func tryFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}
