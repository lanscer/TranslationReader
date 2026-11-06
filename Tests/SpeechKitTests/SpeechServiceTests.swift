import Contracts
import Foundation
import SpeechKit
import Testing

/// 受控假引擎：可指定事件序列与每句耗时，记录 stop 次数。
final class FakeEngine: SpeechEngine, @unchecked Sendable {
    let id: String
    let kind: SpeechEngineKind
    var needsNetwork: Bool { false }
    var scripted: [SpeechEvent] = [.started, .finished]
    var stepDelayNanoseconds: UInt64 = 0

    private let lock = NSLock()
    private var stopCount = 0

    init(id: String, kind: SpeechEngineKind) {
        self.id = id
        self.kind = kind
    }

    var stopCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return stopCount
    }

    func voices(for lang: String) async -> [VoiceOption] { [] }

    func speak(_ text: String, voice: VoiceOption?, rate: Float, volume: Float) -> AsyncStream<SpeechEvent> {
        let events = scripted
        let delay = stepDelayNanoseconds
        return AsyncStream { continuation in
            Task {
                for event in events {
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func stop() {
        lock.lock(); stopCount += 1; lock.unlock()
    }
}

@Suite("引擎切换与降级")
struct SpeechServiceTests {
    @Test("切换引擎立即写入设置")
    func switchPersists() {
        let store = InMemorySpeechSettingsStore()
        let service = SpeechService(store: store, engines: [
            .system: FakeEngine(id: "system", kind: .system),
            .sherpa: FakeEngine(id: "sherpa", kind: .sherpa),
        ])
        #expect(service.engineKind == .system)
        service.setEngine(.sherpa)
        #expect(service.engineKind == .sherpa)
        #expect(store.speech.engine == .sherpa)
        #expect(service.currentEngine.id == "sherpa")
    }

    @Test("播放中切换会先 stop 旧引擎")
    func switchStopsPlayback() async {
        let store = InMemorySpeechSettingsStore()
        let system = FakeEngine(id: "system", kind: .system)
        system.scripted = [.started, .boundary(offset: 0), .finished]
        system.stepDelayNanoseconds = 200_000_000
        let sherpa = FakeEngine(id: "sherpa", kind: .sherpa)
        let service = SpeechService(store: store, engines: [.system: system, .sherpa: sherpa])

        let stream = service.speak("测试", lang: "zh-Hans")
        let consumer = Task { for await _ in stream {} }
        try? await Task.sleep(nanoseconds: 100_000_000)
        service.setEngine(.sherpa)
        #expect(system.stopCalls >= 1, "切换前必须打断旧引擎")
        consumer.cancel()
    }

    @Test("本地引擎失败自动回落系统引擎，且只上报一次")
    func fallbackOnce() async {
        let store = InMemorySpeechSettingsStore()
        store.setEngineKind(.sherpa)
        let sherpa = FakeEngine(id: "sherpa", kind: .sherpa)
        sherpa.scripted = [.failed(.ttsFailed(reason: "模型缺失"))]
        let system = FakeEngine(id: "system", kind: .system)
        system.scripted = [.started, .finished]

        let reported = Latch()
        let counter = FakeCounter()
        let service = SpeechService(
            store: store,
            engines: [.system: system, .sherpa: sherpa],
            fallbackNotice: { _ in counter.increment(); reported.mark() }
        )

        var events: [SpeechEvent] = []
        for await event in service.speak("第一句", lang: "zh-Hans") { events.append(event) }
        #expect(events.contains(.finished), "降级后应拿到系统引擎的完成事件")
        #expect(counter.value == 1)

        for await _ in service.speak("第二句", lang: "zh-Hans") {}
        #expect(counter.value == 1, "同一次会话只告警一次")
    }

    @Test("音色偏好按语种读写")
    func voicePreference() {
        let store = InMemorySpeechSettingsStore()
        store.setVoiceIdentifier("com.apple.voice.premium.zh-CN", for: "zh-Hans")
        #expect(store.voiceIdentifier(for: "zh-Hans") == "com.apple.voice.premium.zh-CN")
        #expect(store.voiceIdentifier(for: "zh-CN") == "com.apple.voice.premium.zh-CN")
        store.setVoiceIdentifier(nil, for: "zh-Hans")
        #expect(store.voiceIdentifier(for: "zh-Hans") == nil)
    }
}

/// 计数标记。
final class FakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func increment() {
        lock.lock(); stored += 1; lock.unlock()
    }
}
