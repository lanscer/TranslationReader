import AVFoundation
import Foundation

/// 播放器抽象：生产实现包 AVAudioPlayer，测试可注入瞬时假播放器。
public protocol SpeechAudioPlaying: AnyObject, Sendable {
    var duration: TimeInterval { get }
    /// 播完返回 true；被打断（stop）返回 false。
    func play() async -> Bool
    func stop()
}

/// AVAudioPlayer 封装：play() 用 continuation 等 didFinish。
public final class AVAudioFilePlayer: NSObject, SpeechAudioPlaying, AVAudioPlayerDelegate, @unchecked Sendable {
    private let player: AVAudioPlayer
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    public var duration: TimeInterval { player.duration }

    public init?(url: URL, volume: Float = 1.0) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        self.player = player
        super.init()
        player.delegate = self
        player.volume = min(max(volume, 0), 1)
        player.prepareToPlay()
    }

    public func play() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            if !player.play() {
                finish(completed: false)
            }
        }
    }

    public func stop() {
        player.stop()
        finish(completed: false)
    }

    private func finish(completed: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: completed)
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(completed: flag)
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(completed: false)
    }
}
