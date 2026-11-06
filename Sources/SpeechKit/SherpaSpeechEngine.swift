import Contracts
import Foundation

/// 播放相位打点（验收「切句间隙 / 首字延迟」时读它）。
public struct SherpaPlaybackTick: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case started
        case finished
    }

    public let phase: Phase
    public let index: Int
    public let total: Int
    public let timestamp: Date
}

/// 本地引擎（文档 §6.6 LocalSherpa / §6.6.1）：子进程逐句合成 wav → 单播放器顺序播放。
///
/// 硬约束：分句队列上限 3 句预取；缓存命中直接播；停止/切换必须立即打断当前播放。
public final class SherpaSpeechEngine: SpeechEngine, @unchecked Sendable {
    public let id = "sherpa"
    public let kind: SpeechEngineKind = .sherpa
    public var needsNetwork: Bool { false }

    /// 说话人 id（多说话人模型才有意义）。
    public var speaker: Int = 0
    /// 中文用哪个模型（设置面板两档：华研快 / 贝壳自然）。
    public var preferredChineseModel: SherpaModelSpec = SherpaModelCatalog.huayan
    /// 预取深度，文档规定上限 3。
    public var prefetchDepth: Int = 3
    /// 播放打点回调（验收实测用）。
    public var onPlaybackTick: (@Sendable (SherpaPlaybackTick) -> Void)?

    private let paths: SherpaPaths
    private let runner: SherpaRunning
    private let cache: SpeechCache
    private let makePlayer: (URL, Float) -> (any SpeechAudioPlaying)?

    private let lock = NSLock()
    private var activeTask: Task<Void, Never>?
    private var activePlayer: (any SpeechAudioPlaying)?
    private var generation = 0

    public init(
        paths: SherpaPaths = SherpaPaths(),
        runner: SherpaRunning = SherpaCLIRunner(),
        cache: SpeechCache = SpeechCache(),
        makePlayer: @escaping (URL, Float) -> (any SpeechAudioPlaying)? = { url, volume in
            AVAudioFilePlayer(url: url, volume: volume)
        }
    ) {
        self.paths = paths
        self.runner = runner
        self.cache = cache
        self.makePlayer = makePlayer
    }

    /// 本地包与模型是否就绪（设置面板据此提示「跑 install-sherpa.sh」）。
    public var isReady: Bool {
        paths.isBinaryInstalled && !paths.installedModels().isEmpty
    }

    public func availableModels() -> [SherpaModelSpec] {
        paths.installedModels()
    }

    /// 本地引擎只有中文/英文本地音色。
    public func voices(for lang: String) async -> [VoiceOption] {
        let specs = paths.installedModels().filter { SpeechLanguage.matches(voiceLanguage: $0.language, lang: lang) }
        if !specs.isEmpty {
            return specs.map {
                VoiceOption(id: $0.id, name: $0.displayName, language: $0.language, quality: .enhanced, engine: .sherpa)
            }
        }
        return availableModels().map {
            VoiceOption(id: $0.id, name: $0.displayName, language: $0.language, quality: .enhanced, engine: .sherpa)
        }
    }

    /// 语种 → 模型；没有可用模型时返回 nil（由 SpeechService 降级）。
    public func resolveModel(for lang: String) -> SherpaModelSpec? {
        let installed = paths.installedModels()
        if SpeechLanguage.isChinese(lang) {
            let chinese = installed.filter { SpeechLanguage.isChinese($0.language) }
            if chinese.contains(preferredChineseModel), paths.isInstalled(preferredChineseModel) {
                return preferredChineseModel
            }
            return chinese.first
        }
        return installed.first { $0.language == SpeechLanguage.bcp47(lang) }
            ?? installed.first { SpeechLanguage.matches(voiceLanguage: $0.language, lang: lang) }
    }

    public func stop() {
        lock.lock()
        generation &+= 1
        let task = activeTask
        let player = activePlayer
        activeTask = nil
        activePlayer = nil
        lock.unlock()
        task?.cancel()
        player?.stop()
    }
}

extension SherpaSpeechEngine {
    public func speak(_ text: String, voice: VoiceOption?, rate: Float, volume: Float) -> AsyncStream<SpeechEvent> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = SentenceSplitter.split(trimmed)
        let lang = voice?.language ?? "zh-CN"

        guard !sentences.isEmpty else {
            return AsyncStream { continuation in
                continuation.yield(.finished)
                continuation.finish()
            }
        }
        guard let spec = resolveModel(for: lang) else {
            let error = SherpaError.noModelForLanguage(lang)
            return AsyncStream { continuation in
                continuation.yield(.failed(error.appError))
                continuation.finish()
            }
        }

        let offsets = Self.sentenceOffsets(in: trimmed, sentences: sentences)
        let plan = SherpaSynthesisPlan(
            spec: spec,
            speaker: speaker,
            speed: min(max(rate, 0.5), 2.0),
            paths: paths
        )
        let depth = max(1, min(prefetchDepth, 3))
        let volumeClamped = min(max(volume, 0), 1)

        lock.lock()
        generation &+= 1
        let token = generation
        lock.unlock()

        return AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let prefetcher = SentencePrefetcher(capacity: depth)
                let producer = Task { [weak self] in
                    guard let self else { return }
                    for (index, sentence) in sentences.enumerated() {
                        if Task.isCancelled { return }
                        await prefetcher.acquire()
                        if Task.isCancelled { return }
                        do {
                            let url = try await self.synthesize(sentence, plan: plan)
                            await prefetcher.push(index, url)
                        } catch {
                            await prefetcher.fail(index, error)
                            return
                        }
                    }
                }

                var startedEmitted = false
                var reportedFailure = false
                for index in sentences.indices {
                    if Task.isCancelled { break }
                    let url: URL
                    do {
                        url = try await prefetcher.take(index)
                    } catch {
                        let appError = (error as? SherpaError)?.appError
                            ?? AppError.ttsFailed(reason: error.localizedDescription)
                        continuation.yield(.failed(appError))
                        reportedFailure = true
                        break
                    }
                    if Task.isCancelled { break }
                    guard let player = self.makePlayer(url, volumeClamped) else {
                        continuation.yield(.failed(SherpaError.invalidOutput(path: url.path).appError))
                        reportedFailure = true
                        break
                    }
                    self.attach(player)
                    if !startedEmitted {
                        continuation.yield(.started)
                        startedEmitted = true
                    }
                    continuation.yield(.boundary(offset: offsets[index]))
                    self.emit(.started, index: index, total: sentences.count)
                    let completed = await player.play()
                    self.emit(.finished, index: index, total: sentences.count)
                    self.detach(player)
                    if !completed { break }
                }

                producer.cancel()
                self.clearTask(token: token)
                if !reportedFailure { continuation.yield(.finished) }
                continuation.finish()
            }
            self.store(task: task, token: token)
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    /// 把句子在原文里的起始字符偏移算出来（boundary 事件用）。
    static func sentenceOffsets(in text: String, sentences: [String]) -> [Int] {
        var offsets: [Int] = []
        var cursor = text.startIndex
        for sentence in sentences {
            if let range = text.range(of: sentence, range: cursor..<text.endIndex) {
                offsets.append(text.distance(from: text.startIndex, to: range.lowerBound))
                cursor = range.upperBound
            } else {
                offsets.append(text.distance(from: text.startIndex, to: cursor))
            }
        }
        return offsets
    }
}

extension SherpaSpeechEngine {
    /// 单句合成：缓存命中直接返回，否则跑子进程并落缓存。
    func synthesize(_ sentence: String, plan: SherpaSynthesisPlan) async throws -> URL {
        let key = SpeechCacheKey(text: sentence, model: plan.spec.id, speaker: plan.speaker, speed: plan.speed)
        if let hit = cache.lookup(key) { return hit }
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let temp = cache.directory.appendingPathComponent("tmp-" + UUID().uuidString + ".wav")
        do {
            try await runner.synthesize(text: sentence, plan: plan, outputURL: temp)
            let stored = try cache.store(temp, for: key)
            cache.pruneIfNeeded()
            return stored
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private func emit(_ phase: SherpaPlaybackTick.Phase, index: Int, total: Int) {
        onPlaybackTick?(SherpaPlaybackTick(phase: phase, index: index, total: total, timestamp: Date()))
    }

    private func attach(_ player: any SpeechAudioPlaying) {
        lock.lock()
        activePlayer = player
        lock.unlock()
    }

    private func detach(_ player: any SpeechAudioPlaying) {
        lock.lock()
        if let current = activePlayer, current === player { activePlayer = nil }
        lock.unlock()
    }

    private func store(task: Task<Void, Never>, token: Int) {
        lock.lock()
        if generation == token { activeTask = task } else { task.cancel() }
        lock.unlock()
    }

    private func clearTask(token: Int) {
        lock.lock()
        if generation == token { activeTask = nil }
        lock.unlock()
    }
}
