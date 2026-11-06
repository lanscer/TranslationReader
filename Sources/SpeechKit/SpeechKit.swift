import Contracts
import Foundation

/// SpeechKit 门面（文档 §5.2 模块划分：本库只依赖 Contracts）。
///
/// 两个完整引擎：系统 AVSpeechSynthesizer（SystemSpeechEngine）与本地
/// sherpa-onnx 子进程（SherpaSpeechEngine）；云端 /audio/speech 档留给 M5。
public enum SpeechKit {
    public static let moduleName = "SpeechKit"

    /// 引擎工厂。openai 档本版不实现（文档 §6.6 标为「用户填了语音模型时可选」）。
    public static func makeEngine(kind: SpeechEngineKind) -> SpeechEngine? {
        switch kind {
        case .system:
            return SystemSpeechEngine()
        case .sherpa:
            return SherpaSpeechEngine()
        case .openai:
            return nil
        }
    }

    /// 当前可用引擎（设置面板三段式选择器的数据源）。
    public static func availableEngines() -> [SpeechEngineKind] {
        SpeechEngineKind.allCases.filter { makeEngine(kind: $0) != nil }
    }

    /// 本地引擎是否已部署（决定 sherpa 档是否可选）。
    public static func isSherpaInstalled() -> Bool {
        let paths = SherpaPaths()
        return paths.isBinaryInstalled && !paths.installedModels().isEmpty
    }

    /// 默认朗读总入口：读 UserDefaults 里的 speech 设置。
    public static func makeService(
        fallbackNotice: (@Sendable (AppError) -> Void)? = nil
    ) -> SpeechService {
        SpeechService(fallbackNotice: fallbackNotice)
    }
}

/// sherpa 档自己的偏好（AppSettings.Speech 没有模型字段，Contracts 冻结，故本库自持）。
public struct SherpaModelPreference: Sendable {
    public static let defaultsKey = "speech.sherpa.model"
    public static let speakerKey = "speech.sherpa.speaker"

    public var modelID: String
    public var speaker: Int

    public init(modelID: String = SherpaModelCatalog.huayan.id, speaker: Int = 0) {
        self.modelID = modelID
        self.speaker = speaker
    }

    public static func load(from defaults: UserDefaults = .standard) -> SherpaModelPreference {
        SherpaModelPreference(
            modelID: defaults.string(forKey: defaultsKey) ?? SherpaModelCatalog.huayan.id,
            speaker: defaults.integer(forKey: speakerKey)
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(modelID, forKey: Self.defaultsKey)
        defaults.set(speaker, forKey: Self.speakerKey)
    }

    public var spec: SherpaModelSpec {
        SherpaModelCatalog.spec(id: modelID) ?? SherpaModelCatalog.huayan
    }
}
