import Foundation
import AppKit

/// 单实例互斥：
/// 1) 同 bundle id 已有进程 → 激活它并让新实例退出；
/// 2) 直接跑 swift build 产物（无 bundle id）时，用 flock 独占锁兜底。
final class SingleInstanceLock {
    static let shared = SingleInstanceLock()

    static let bundleIdentifier = "com.local.translationreader"

    private var lockFileDescriptor: Int32 = -1

    private var lockFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("TranslationReader", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    /// 抢锁成功返回 true；已有实例返回 false（调用方应退出）。
    func acquire() -> Bool {
        if activateExistingInstance() {
            return false
        }

        let url = lockFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            // 拿不到锁文件时宁可启动，也不把用户挡在外面。
            AppLog.echo("无法打开单实例锁文件，跳过互斥：\(url.path)", AppLog.lifecycle)
            return true
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }

        lockFileDescriptor = fd
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    /// 已有同 bundle id 实例时激活它（并返回 true）。
    @discardableResult
    func activateExistingInstance() -> Bool {
        let selfPID = getpid()
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .filter { $0.processIdentifier != selfPID }
        guard let existing = others.first else { return false }
        existing.activate(options: [])
        AppLog.echo("检测到已在运行（pid \(existing.processIdentifier)），激活旧实例后退出新实例", AppLog.lifecycle)
        return true
    }
}
