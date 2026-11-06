import Contracts
import Foundation

/// 本地 sherpa-onnx 的一个可下载模型（文档 §6.6.1）。
public struct SherpaModelSpec: Hashable, Sendable, Identifiable {
    public enum Family: String, Hashable, Sendable {
        /// piper 系 VITS：单个 onnx + tokens。
        case vits
        /// Matcha：声学模型 + 独立 vocoder + lexicon。
        case matcha
    }

    /// 同时是磁盘目录名与缓存键里的 model 字段。
    public let id: String
    public let displayName: String
    /// 该模型覆盖的语种（BCP-47）。
    public let language: String
    public let family: Family
    /// 模型目录内的主 onnx 文件名。
    public let onnxFile: String

    public init(id: String, displayName: String, language: String, family: Family, onnxFile: String) {
        self.id = id
        self.displayName = displayName
        self.language = language
        self.family = family
        self.onnxFile = onnxFile
    }
}

/// install-sherpa.sh 落地的模型清单（与脚本里的 SHA256 表一一对应）。
public enum SherpaModelCatalog {
    /// 中文·快（vits-piper 华研 medium）。
    public static let huayan = SherpaModelSpec(
        id: "vits-piper-zh_CN-huayan-medium",
        displayName: "华研 · 中等（快）",
        language: "zh-CN",
        family: .vits,
        onnxFile: "zh_CN-huayan-medium.onnx"
    )

    /// 中文·自然（matcha-icefall 贝壳）。
    public static let baker = SherpaModelSpec(
        id: "matcha-icefall-zh-baker",
        displayName: "贝壳 Matcha（自然）",
        language: "zh-CN",
        family: .matcha,
        onnxFile: "model-steps-3.onnx"
    )

    /// 英文（vits-piper amy medium）。
    public static let amy = SherpaModelSpec(
        id: "vits-piper-en_US-amy-medium",
        displayName: "Amy · 英文中等",
        language: "en-US",
        family: .vits,
        onnxFile: "en_US-amy-medium.onnx"
    )

    public static let all: [SherpaModelSpec] = [huayan, baker, amy]

    /// 设置面板里「中文模型」两档，顺序即 UI 顺序（先快后自然）。
    public static let chinese: [SherpaModelSpec] = [huayan, baker]

    public static func spec(id: String) -> SherpaModelSpec? {
        all.first { $0.id == id }
    }
}

/// 本地引擎的磁盘布局（scripts/install-sherpa.sh 与文档 §6.6.1 同源）。
public struct SherpaPaths: Hashable, Sendable {
    public let root: URL

    public init(root: URL = SherpaPaths.defaultRoot) {
        self.root = root
    }

    /// ~/Library/Application Support/TranslationReader/models/sherpa-onnx
    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("TranslationReader", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("sherpa-onnx", isDirectory: true)
    }

    /// 官方预编译包里的 TTS 命令行（v2.0.1 实测文件名）。
    public var binaryURL: URL {
        root.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("sherpa-onnx-offline-tts")
    }

    public var libDirectory: URL {
        root.appendingPathComponent("lib", isDirectory: true)
    }

    public func modelDirectory(_ spec: SherpaModelSpec) -> URL {
        root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(spec.id, isDirectory: true)
    }

    /// Matcha 系共用的 vocoder。
    public var vocoderURL: URL {
        root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("vocoder", isDirectory: true)
            .appendingPathComponent("vocos-22khz-univ.onnx")
    }

    public var isBinaryInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }

    public func isInstalled(_ spec: SherpaModelSpec) -> Bool {
        let dir = modelDirectory(spec)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(spec.onnxFile).path),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path)
        else { return false }
        if spec.family == .matcha {
            return FileManager.default.fileExists(atPath: vocoderURL.path)
        }
        return true
    }

    /// 可用于某个语种的模型（中文优先用户选择，英文只有 amy）。
    public func installedModels() -> [SherpaModelSpec] {
        SherpaModelCatalog.all.filter { isInstalled($0) }
    }
}

/// 本地引擎的错误；文案直接引导用户跑安装脚本（文档 §6.6.1）。
public enum SherpaError: Error, Equatable, LocalizedError, Sendable {
    case binaryMissing(path: String)
    case modelMissing(model: String, path: String)
    case vocoderMissing(path: String)
    case noModelForLanguage(String)
    case synthesisFailed(exitCode: Int32, stderr: String)
    case invalidOutput(path: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .binaryMissing(let path):
            return "未找到 sherpa-onnx-offline-tts（\(path)）。请先运行 scripts/install-sherpa.sh。"
        case .modelMissing(let model, let path):
            return "缺少本地模型 \(model)（\(path)）。请先运行 scripts/install-sherpa.sh。"
        case .vocoderMissing(let path):
            return "缺少 Matcha vocoder（\(path)）。请先运行 scripts/install-sherpa.sh。"
        case .noModelForLanguage(let lang):
            return "本地引擎没有 \(lang) 的模型，请安装对应模型或切换到系统引擎。"
        case .synthesisFailed(let code, let stderr):
            let detail = stderr.isEmpty ? "无输出" : String(stderr.suffix(400))
            return "sherpa-onnx 合成失败（exit \(code)）：\(detail)"
        case .invalidOutput(let path):
            return "sherpa-onnx 没有生成有效 wav：\(path)"
        case .cancelled:
            return "朗读已取消。"
        }
    }

    /// 转成跨模块统一错误，交给 UI 展示。
    public var appError: AppError {
        switch self {
        case .cancelled: return .cancelled
        default: return .ttsFailed(reason: errorDescription ?? "未知错误")
        }
    }
}
