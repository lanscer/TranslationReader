import Foundation
import os
import ApplicationServices
import CoreGraphics
import TranslateKit

/// 一条日志通道：一级分类标签 + os_log 的 category。
struct AppLogChannel: Sendable {
    let tag: String
    let logger: Logger
}

/// 统一日志出口（双写）：
/// 1) stderr —— 终端启动时直接看得到；
/// 2) ~/Library/Logs/TranslationReader/app.log —— 从 Finder / 双击启动时唯一的现场；
/// 每条带 ISO8601 时间戳与一级分类标签，单文件超过 2MB 轮转为 app.log.1。
/// 所有内容先过 TranslateKit.Redaction，绝不落 apiKey。
enum AppLog {
    private static let subsystem = "com.local.translationreader"

    static let lifecycle = AppLogChannel(tag: "app", logger: Logger(subsystem: subsystem, category: "lifecycle"))
    static let menu = AppLogChannel(tag: "ui", logger: Logger(subsystem: subsystem, category: "menu"))
    static let ui = AppLogChannel(tag: "ui", logger: Logger(subsystem: subsystem, category: "ui"))
    static let perm = AppLogChannel(tag: "perm", logger: Logger(subsystem: subsystem, category: "permission"))
    static let ax = AppLogChannel(tag: "ax", logger: Logger(subsystem: subsystem, category: "selection"))
    static let speech = AppLogChannel(tag: "speech", logger: Logger(subsystem: subsystem, category: "speech"))
    static let translate = AppLogChannel(tag: "translate", logger: Logger(subsystem: subsystem, category: "translate"))

    /// 同时打 os_log、stderr 与日志文件。
    static func echo(_ message: String, _ channel: AppLogChannel = AppLog.lifecycle) {
        let safe = Redaction.scrub(message, secrets: LogSecrets.current())
        channel.logger.notice("\(safe, privacy: .public)")
        FileHandle.standardError.write(Data("[TranslationReader] \(safe)\n".utf8))
        FileLogSink.shared.write(tag: channel.tag, message: safe)
    }

    /// 启动时的环境摘要：版本 / bundle / 签名身份 / TCC 状态。
    /// 排查「勾了还是不生效」时，这一行就能确认「跑的是哪份二进制、以什么身份登记」。
    static func snapshotEnvironment(version: String) {
        let signing = SigningDiagnostics.describe()
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let pid = ProcessInfo.processInfo.processIdentifier
        echo("环境摘要 version=\(version) pid=\(pid) bundle=\(signing.bundlePath) 签名=\(signing.identity) 辅助功能=\(accessibility ? "已授权" : "未授权") 屏幕录制=\(screenRecording ? "已授权" : "未授权") 日志=\(FileLogSink.fileURL.path)", AppLog.lifecycle)
    }
}

/// 需要从日志里抹掉的密钥（SettingsModel 保存 key 后登记，交给 Redaction 兜底）。
enum LogSecrets {
    private static let lock = NSLock()
    private static var secrets: [String] = []

    static func register(_ secret: String) {
        guard secret.count >= 6 else { return }
        lock.lock()
        if !secrets.contains(secret) { secrets.append(secret) }
        lock.unlock()
    }

    static func current() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return secrets
    }
}

/// 日志文件写入器：自动建目录、追加写、2MB 轮转。
final class FileLogSink: @unchecked Sendable {
    static let shared = FileLogSink()
    static let maxBytes: UInt64 = 2 * 1024 * 1024

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TranslationReader", isDirectory: true)
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("app.log") }
    static var rotatedURL: URL { directoryURL.appendingPathComponent("app.log.1") }

    private let lock = NSLock()
    private var handle: FileHandle?

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    func write(tag: String, message: String) {
        let line = Self.formatter.string(from: Date()) + " [" + tag + "] " + message + "\n"
        lock.lock()
        defer { lock.unlock() }
        guard let handle = openIfNeeded() else { return }
        handle.write(Data(line.utf8))
        rotateIfNeeded(handle)
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        do {
            try FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
                FileManager.default.createFile(atPath: Self.fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: Self.fileURL)
            try handle.seekToEnd()
            self.handle = handle
            return handle
        } catch {
            return nil
        }
    }

    private func rotateIfNeeded(_ handle: FileHandle) {
        guard handle.offsetInFile > Self.maxBytes else { return }
        try? handle.close()
        self.handle = nil
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: Self.rotatedURL)
        try? fileManager.moveItem(at: Self.fileURL, to: Self.rotatedURL)
        _ = openIfNeeded()
    }
}

