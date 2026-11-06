import Foundation

/// 一次本地合成的请求参数（缓存键 = text|model|speaker|speed）。
public struct SherpaSynthesisPlan: Hashable, Sendable {
    public let spec: SherpaModelSpec
    public let speaker: Int
    public let speed: Float
    public let paths: SherpaPaths

    public init(spec: SherpaModelSpec, speaker: Int, speed: Float, paths: SherpaPaths) {
        self.spec = spec
        self.speaker = speaker
        self.speed = speed
        self.paths = paths
    }
}

/// 合成器抽象：生产实现跑 sherpa-onnx-offline-tts 子进程，测试可注入假实现。
public protocol SherpaRunning: Sendable {
    /// 把 text 合成到 outputURL（wav）。失败必须抛错，调用方据此上报并降级。
    func synthesize(text: String, plan: SherpaSynthesisPlan, outputURL: URL) async throws
}

/// 子进程实现：sherpa-onnx-offline-tts（文档 §6.6.1「调用形态」）。
///
/// 参数取自官方 --help 实测输出（v1.13.8 与 v2.0.1 都含这些 flag）：
/// vits 系：--vits-model --vits-tokens --vits-lexicon --vits-data-dir --vits-length-scale
/// matcha 系：--matcha-acoustic-model --matcha-vocoder --matcha-tokens --matcha-lexicon --matcha-length-scale
/// 公共：--sid --num-threads --output-filename，待合成文本作为位置参数。
public struct SherpaCLIRunner: SherpaRunning {
    /// 单句合成超时（冷启动 300-600ms，给足余量）。
    public var timeout: TimeInterval
    public var numThreads: Int

    public init(timeout: TimeInterval = 60, numThreads: Int = 2) {
        self.timeout = timeout
        self.numThreads = numThreads
    }

    public func synthesize(text: String, plan: SherpaSynthesisPlan, outputURL: URL) async throws {
        let executable = plan.paths.binaryURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SherpaError.binaryMissing(path: executable.path)
        }
        let arguments = try Self.arguments(text: text, plan: plan, outputURL: outputURL, numThreads: numThreads)
        try await runProcess(executable: executable, arguments: arguments, workingDirectory: plan.paths.root)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SherpaError.invalidOutput(path: outputURL.path)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > 1024 else { throw SherpaError.invalidOutput(path: outputURL.path) }
    }
}

extension SherpaCLIRunner {
    /// 纯函数：便于单测断言参数拼装（不启动进程）。
    public static func arguments(
        text: String,
        plan: SherpaSynthesisPlan,
        outputURL: URL,
        numThreads: Int = 2
    ) throws -> [String] {
        let dir = plan.paths.modelDirectory(plan.spec)
        let fileManager = FileManager.default
        let onnx = dir.appendingPathComponent(plan.spec.onnxFile)
        guard fileManager.fileExists(atPath: onnx.path) else {
            throw SherpaError.modelMissing(model: plan.spec.id, path: onnx.path)
        }
        let tokens = dir.appendingPathComponent("tokens.txt")
        let lengthScale = 1.0 / min(max(plan.speed, 0.5), 2.0)

        var args: [String] = []
        switch plan.spec.family {
        case .vits:
            args.append("--vits-model=" + onnx.path)
            args.append("--vits-tokens=" + tokens.path)
            let lexicon = dir.appendingPathComponent("lexicon.txt")
            if fileManager.fileExists(atPath: lexicon.path) {
                args.append("--vits-lexicon=" + lexicon.path)
            }
            let espeakData = dir.appendingPathComponent("espeak-ng-data", isDirectory: true)
            if fileManager.fileExists(atPath: espeakData.path) {
                args.append("--vits-data-dir=" + espeakData.path)
            }
            args.append("--vits-length-scale=" + String(format: "%.3f", lengthScale))
        case .matcha:
            let vocoder = plan.paths.vocoderURL
            guard fileManager.fileExists(atPath: vocoder.path) else {
                throw SherpaError.vocoderMissing(path: vocoder.path)
            }
            args.append("--matcha-acoustic-model=" + onnx.path)
            args.append("--matcha-vocoder=" + vocoder.path)
            args.append("--matcha-tokens=" + tokens.path)
            var lexicons: [String] = []
            for name in ["lexicon.txt", "lexicon-en-us.txt"] {
                let candidate = dir.appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) { lexicons.append(candidate.path) }
            }
            if !lexicons.isEmpty {
                args.append("--matcha-lexicon=" + lexicons.joined(separator: ","))
            }
            args.append("--matcha-length-scale=" + String(format: "%.3f", lengthScale))
        }
        args.append("--sid=" + String(plan.speaker))
        args.append("--num-threads=" + String(numThreads))
        args.append("--output-filename=" + outputURL.path)
        args.append(text)
        return args
    }
}

extension SherpaCLIRunner {
    private func runProcess(executable: URL, arguments: [String], workingDirectory: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        let libPath = workingDirectory.appendingPathComponent("lib", isDirectory: true).path
        let existing = environment["DYLD_LIBRARY_PATH"]
        environment["DYLD_LIBRARY_PATH"] = existing.map { libPath + ":" + $0 } ?? libPath
        process.environment = environment

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        let deadline = self.timeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = SherpaCompletionBox(continuation: continuation)
            process.terminationHandler = { finished in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                box.finish(exitCode: finished.terminationStatus, stderr: text)
            }
            do {
                try process.run()
            } catch {
                box.finish(exitCode: -1, stderr: error.localizedDescription)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                if process.isRunning {
                    process.terminate()
                    box.finish(exitCode: -2, stderr: "timeout after \(Int(deadline))s")
                }
            }
        }
    }
}

/// 保证 continuation 只 resume 一次。
final class SherpaCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(exitCode: Int32, stderr: String) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if exitCode == 0 {
            pending.resume()
        } else {
            pending.resume(throwing: SherpaError.synthesisFailed(exitCode: exitCode, stderr: stderr))
        }
    }
}
