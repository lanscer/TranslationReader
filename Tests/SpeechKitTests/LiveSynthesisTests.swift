import Contracts
import Foundation
import SpeechKit
import Testing

/// 把实测数字同时打到 stdout 与 /tmp/speechkit-live-report.txt（验收证据）。
final class LiveReport: @unchecked Sendable {
    static let path = "/tmp/speechkit-live-report.txt"
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        let snapshot = lines
        lock.unlock()
        print("[LIVE] " + line)
        try? snapshot.joined(separator: "\n").write(
            toFile: LiveReport.path,
            atomically: true,
            encoding: .utf8
        )
    }
}

enum LiveClock {
    static func milliseconds(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[sorted.count / 2]
    }
}

@Suite("实测：系统引擎（SPEECHKIT_LIVE_TTS=1）")
struct SystemEngineLiveTests {
    static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["SPEECHKIT_LIVE_TTS"] == "1"
    }

    /// 等到首个 boundary（真正开始发音）或超时。
    func firstBoundaryMilliseconds(engine: SpeechEngine, text: String, lang: String, timeout: Double) async -> Double? {
        let start = Date()
        let box = TimeoutBox()
        return await withTaskGroup(of: Double?.self) { group in
            group.addTask {
                for await event in engine.speak(text, voice: nil, rate: 1.0, volume: 0.9) {
                    if case .boundary = event { return LiveClock.milliseconds(since: start) }
                    if case .failed = event { return nil }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                box.mark()
                return nil
            }
            let first = await group.next() ?? nil
            engine.stop()
            group.cancelAll()
            return first
        }
    }

    @Test("中文/英文各 3 次首字延迟", .enabled(if: SystemEngineLiveTests.liveEnabled))
    func systemLatency() async {
        let report = LiveReport()
        let engine = SystemSpeechEngine()
        let voices = await engine.voices(for: "zh-Hans")
        report.add("系统音色（zh-Hans）：\(voices.count) 个，最高质量 = \(voices.first?.name ?? "无") / \(voices.first?.quality.displayName ?? "-")")

        for sample in [("今天天气不错，我们出去走走吧。", "zh-Hans"), ("Good morning, this is a latency test.", "en")] {
            var samples: [Double] = []
            for index in 1...3 {
                if let value = await firstBoundaryMilliseconds(engine: engine, text: sample.0, lang: sample.1, timeout: 20) {
                    samples.append(value)
                    report.add("系统引擎 \(sample.1) 第\(index)次首字延迟 \(String(format: "%.1f", value))ms")
                } else {
                    report.add("系统引擎 \(sample.1) 第\(index)次首字延迟：超时/失败（无音频设备？）")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if samples.count == 3 {
                report.add("系统引擎 \(sample.1) 首字延迟中位数 \(String(format: "%.1f", LiveClock.median(samples)))ms")
            }
        }
    }
}

/// 超时标记（仅用于结束 race，不参与断言）。
final class TimeoutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func mark() {
        lock.lock(); fired = true; lock.unlock()
    }
    var didFire: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}
