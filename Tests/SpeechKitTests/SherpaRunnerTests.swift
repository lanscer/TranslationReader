import Foundation
import SpeechKit
import Testing

@Suite("sherpa 命令行参数拼装")
struct SherpaRunnerTests {
    /// 造一个假的落地目录（只放占位文件，不跑进程）。
    func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speechkit-sherpa-" + UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        for spec in SherpaModelCatalog.all {
            let dir = root.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(spec.id, isDirectory: true)
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(spec.onnxFile))
            try Data().write(to: dir.appendingPathComponent("tokens.txt"))
        }
        try manager.createDirectory(
            at: root.appendingPathComponent("models/vocoder", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("models/vocoder/vocos-22khz-univ.onnx"))
        return root
    }

    @Test("vits 模型用 --vits-* 参数，文本是位置参数")
    func vitsArguments() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SherpaPaths(root: root)
        let plan = SherpaSynthesisPlan(spec: SherpaModelCatalog.huayan, speaker: 3, speed: 1.0, paths: paths)
        let output = root.appendingPathComponent("out.wav")

        let args = try SherpaCLIRunner.arguments(text: "你好。", plan: plan, outputURL: output)
        #expect(args.contains("--vits-model=" + paths.modelDirectory(SherpaModelCatalog.huayan).appendingPathComponent("zh_CN-huayan-medium.onnx").path))
        #expect(args.contains("--vits-tokens=" + paths.modelDirectory(SherpaModelCatalog.huayan).appendingPathComponent("tokens.txt").path))
        #expect(args.contains("--sid=3"))
        #expect(args.contains("--output-filename=" + output.path))
        #expect(args.contains { $0.hasPrefix("--vits-length-scale=1.000") })
        #expect(args.last == "你好。")
    }

    @Test("matcha 模型用 --matcha-* 参数并带 vocoder")
    func matchaArguments() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SherpaPaths(root: root)
        let plan = SherpaSynthesisPlan(spec: SherpaModelCatalog.baker, speaker: 0, speed: 1.5, paths: paths)
        let output = root.appendingPathComponent("out.wav")

        let args = try SherpaCLIRunner.arguments(text: "大家好。", plan: plan, outputURL: output)
        #expect(args.contains { $0.hasPrefix("--matcha-acoustic-model=") })
        #expect(args.contains("--matcha-vocoder=" + paths.vocoderURL.path))
        #expect(args.contains { $0.hasPrefix("--matcha-length-scale=0.66") || $0.hasPrefix("--matcha-length-scale=0.667") })
    }

    @Test("模型缺失时抛明确错误并提示跑安装脚本")
    func missingModel() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SherpaPaths(root: root)
        let empty = root.appendingPathComponent("models/vits-piper-zh_CN-huayan-medium/zh_CN-huayan-medium.onnx")
        try FileManager.default.removeItem(at: empty)
        let plan = SherpaSynthesisPlan(spec: SherpaModelCatalog.huayan, speaker: 0, speed: 1.0, paths: paths)

        do {
            _ = try SherpaCLIRunner.arguments(text: "你好。", plan: plan, outputURL: root.appendingPathComponent("o.wav"))
            Issue.record("应当抛 modelMissing")
        } catch let error as SherpaError {
            #expect(error.errorDescription?.contains("install-sherpa.sh") == true)
        }
    }

    @Test("路径布局与安装脚本一致")
    func pathLayout() {
        let root = URL(fileURLWithPath: "/tmp/sherpa-root")
        let paths = SherpaPaths(root: root)
        #expect(paths.binaryURL.path == "/tmp/sherpa-root/bin/sherpa-onnx-offline-tts")
        #expect(paths.vocoderURL.path == "/tmp/sherpa-root/models/vocoder/vocos-22khz-univ.onnx")
        #expect(paths.modelDirectory(SherpaModelCatalog.baker).lastPathComponent == "matcha-icefall-zh-baker")
    }
}
