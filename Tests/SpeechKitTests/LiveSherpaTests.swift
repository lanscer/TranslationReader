import Contracts
import Foundation
import SpeechKit
import Testing

/// 记录播放打点，供「切句间隙」计算。
final class TickRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [SherpaPlaybackTick] = []

    func record(_ tick: SherpaPlaybackTick) {
        lock.lock(); ticks.append(tick); lock.unlock()
    }

    func reset() {
        lock.lock(); ticks.removeAll(); lock.unlock()
    }

    func snapshot() -> [SherpaPlaybackTick] {
        lock.lock(); defer { lock.unlock() }
        return ticks
    }

    /// 第 n 句开始 与 第 n-1 句结束 的间隔（毫秒）。
    func gaps() -> [Double] {
        let all = snapshot()
        var result: [Double] = []
        for (index, tick) in all.enumerated() where tick.phase == .started && tick.index > 0 {
            guard let previousFinish = all[..<index].last(where: { $0.index == tick.index - 1 && $0.phase == .finished })
            else { continue }
            result.append(tick.timestamp.timeIntervalSince(previousFinish.timestamp) * 1000)
        }
        return result
    }
}

@Suite("实测：本地 sherpa 引擎（SPEECHKIT_LIVE_TTS=1）")
struct SherpaEngineLiveTests {
    static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["SPEECHKIT_LIVE_TTS"] == "1"
    }

    let chineseText = "今天天气不错。我们出去走走吧。好吗？"

    @Test("首字延迟 / 缓存命中 / 切句间隙", .enabled(if: SherpaEngineLiveTests.liveEnabled))
    func sherpaMetrics() async {
        let report = LiveReport()
        let paths = SherpaPaths()
        guard paths.isBinaryInstalled else {
            report.add("本地引擎未安装：\(paths.root.path)")
            return
        }
        report.add("本地引擎根目录：\(paths.root.path)")
        report.add("已装模型：\(paths.installedModels().map { $0.id }.joined(separator: ", "))")

        let cache = SpeechCache()
        let recorder = TickRecorder()
        let engine = SherpaSpeechEngine(paths: paths, cache: cache)
        engine.preferredChineseModel = SherpaModelCatalog.huayan
        engine.onPlaybackTick = { tick in recorder.record(tick) }
        let voice = VoiceOption(id: "", name: "huayan", language: "zh-CN", quality: .enhanced, engine: .sherpa)

        var firstAudio: [Double] = []
        for run in 1...3 {
            recorder.reset()
            let start = Date()
            var boundary: Double?
            for await event in engine.speak(chineseText, voice: voice, rate: 1.0, volume: 0.0) {
                if case .boundary = event, boundary == nil {
                    boundary = LiveClock.milliseconds(since: start)
                }
            }
            if let boundary {
                firstAudio.append(boundary)
                let label = run == 1 ? "冷启" : "缓存命中"
                report.add("本地引擎 中文 第\(run)次（\(label)）首字延迟 \(String(format: "%.1f", boundary))ms")
            }
            let gaps = recorder.gaps()
            if !gaps.isEmpty {
                let text = gaps.map { String(format: "%.1f", $0) }.joined(separator: ", ")
                report.add("本地引擎 第\(run)次 切句间隙 [\(text)]ms，最大 \(String(format: "%.1f", gaps.max() ?? 0))ms")
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if firstAudio.count == 3 {
            report.add("本地引擎 首字延迟中位数 \(String(format: "%.1f", LiveClock.median(firstAudio)))ms")
        }
    }

    @Test("英文句子也能本地合成", .enabled(if: SherpaEngineLiveTests.liveEnabled))
    func englishSentence() async {
        let report = LiveReport()
        let paths = SherpaPaths()
        guard paths.isInstalled(SherpaModelCatalog.amy) else {
            report.add("英文模型未安装（--skip-english？）")
            return
        }
        let engine = SherpaSpeechEngine(paths: paths, cache: SpeechCache())
        let voice = VoiceOption(id: "", name: "amy", language: "en-US", quality: .enhanced, engine: .sherpa)
        let start = Date()
        var boundary: Double?
        for await event in engine.speak("Good morning, this is a local engine test.", voice: voice, rate: 1.0, volume: 0.0) {
            if case .boundary = event, boundary == nil { boundary = LiveClock.milliseconds(since: start) }
            if case .failed(let error) = event { report.add("本地引擎英文失败：\(error.userMessage)") }
        }
        if let boundary {
            report.add("本地引擎 英文 首字延迟 \(String(format: "%.1f", boundary))ms")
        }
    }
}
