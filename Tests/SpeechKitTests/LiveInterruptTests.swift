import Contracts
import Foundation
import SpeechKit
import Testing

@Suite("实测：stop 立即打断（SPEECHKIT_LIVE_TTS=1）")
struct LiveInterruptTests {
    static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["SPEECHKIT_LIVE_TTS"] == "1"
    }

    let longText = "这是一段比较长的文本，用来验证打断是否立即生效。"
        + "第二句继续朗读，确保播放不会因为句子太短而提前结束。"
        + "第三句依然在朗读中。"

    @Test("系统引擎 stop 打断耗时", .enabled(if: LiveInterruptTests.liveEnabled))
    func systemStop() async {
        let report = LiveReport()
        let engine = SystemSpeechEngine()
        let stopAt = Date()
        var interrupted = false
        let deadline = stopAt.addingTimeInterval(0.45)

        let task = Task {
            for await event in engine.speak(longText, voice: nil, rate: 1.0, volume: 0.0) {
                if event == .finished {
                    interrupted = true
                }
            }
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        let stopTime = Date()
        engine.stop()
        _ = await task.result

        let elapsed = Date().timeIntervalSince(stopTime) * 1000
        report.add("系统引擎 stop→流结束 \(String(format: "%.1f", elapsed))ms（收到 finished：\(interrupted)）")
        _ = deadline
    }

    @Test("本地引擎 stop 打断耗时（播放中）", .enabled(if: LiveInterruptTests.liveEnabled))
    func sherpaStop() async {
        let report = LiveReport()
        let paths = SherpaPaths()
        guard paths.isBinaryInstalled else {
            report.add("本地引擎未安装，跳过")
            return
        }
        let cache = SpeechCache()
        let voice = VoiceOption(id: "", name: "huayan", language: "zh-CN", quality: .enhanced, engine: .sherpa)
        let engine = SherpaSpeechEngine(paths: paths, cache: cache)

        // 先热一次缓存，保证打断发生在播放阶段而不是合成阶段
        for await _ in engine.speak("预热。", voice: voice, rate: 1.0, volume: 0.0) {}

        let task = Task {
            for await _ in engine.speak(longText, voice: voice, rate: 1.0, volume: 0.0) {}
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        let stopTime = Date()
        engine.stop()
        _ = await task.result
        let elapsed = Date().timeIntervalSince(stopTime) * 1000
        report.add("本地引擎 stop→流结束 \(String(format: "%.1f", elapsed))ms")
    }
}
