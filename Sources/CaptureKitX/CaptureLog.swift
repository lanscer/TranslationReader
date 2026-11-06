import Foundation

/// 截图链路的 [ax] 级诊断日志。
///
/// 优先级：
///  1) `CaptureLog.sink`（AppShell 可一行接上统一日志：`CaptureLog.sink = { AppLog.echo($0, AppLog.ax) }`，
///     这样能复用 AppLog 的 os_log + stderr + 2MB 轮转与密钥脱敏）；
///  2) 没接 sink 时，直接按**完全相同**的行格式（ISO8601 [ax] message）追加到
///     ~/Library/Logs/TranslationReader/app.log，保证用户报「截图没反应」时现场日志里一定有这条。
///
/// 为什么要打这条：`CGPreflightScreenCaptureAccess()` 与 `SCShareableContent.displays` 是两个独立故障面
/// —— 预检 true 但显示器列表为空（休眠/锁屏/截屏服务未就绪）与「真的没授权」在 UI 上看起来一样，
/// 只有日志能把两者分开。
public enum CaptureLog {

    /// AppShell 接入点；nil 时走文件兜底。
    public static var sink: ((String) -> Void)?

    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TranslationReader", isDirectory: true)
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("app.log") }

    public static func ax(_ message: String) {
        if let sink {
            sink(message)
            return
        }
        let line = formatter.string(from: Date()) + " [ax] " + message + "\n"
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        try? manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}