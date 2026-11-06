import AppKit
import Carbon

public enum HotkeyRegistrationError: Error, Equatable, Sendable {
    /// combo 字符串无法解析，或缺少修饰键（裸字母）。
    case invalidCombo(String)
    /// 同一个 combo 在本进程内重复注册（冲突检测）。
    case duplicateCombo(String)
    /// Carbon 拒绝注册（典型：系统或其他 App 已占用，返回 eventHotKeyExistsErr -9878）。
    case systemRejected(combo: String, status: OSStatus)
}

extension HotkeyRegistrationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCombo(let combo): return "快捷键 \"\(combo)\" 无法解析"
        case .duplicateCombo(let combo): return "快捷键 \"\(combo)\" 已注册，冲突"
        case .systemRejected(let combo, let status): return "系统拒绝注册 \"\(combo)\"（OSStatus \(status)）"
        }
    }
}

/// 文档 §7：Carbon RegisterEventHotKey 注册器。零 TCC 权限；
/// 注销走 UnregisterEventHotKey，deinit 与 shutdown() 一并移除事件处理器，不留悬挂引用。
public final class HotkeyRegistry: @unchecked Sendable {
    public typealias Handler = @Sendable (HotkeyCombo) -> Void

    private struct Entry {
        let combo: HotkeyCombo
        let ref: EventHotKeyRef
        let handler: Handler
    }

    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    private var idByCombo: [HotkeyCombo: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    /// 'DSHK'
    private static let signature: OSType = 0x4453_484B

    public init() {}

    deinit {
        teardown()
    }

    public var registeredCombos: [HotkeyCombo] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.map(\.combo).sorted { $0.string < $1.string }
    }

    public func isRegistered(_ combo: HotkeyCombo) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return idByCombo[combo] != nil
    }

    @discardableResult
    public func register(_ comboString: String, handler: @escaping Handler) -> Result<HotkeyCombo, HotkeyRegistrationError> {
        guard let combo = HotkeyCombo(string: comboString) else {
            return .failure(.invalidCombo(comboString))
        }
        return register(combo, handler: handler)
    }

    @discardableResult
    public func register(_ combo: HotkeyCombo, handler: @escaping Handler) -> Result<HotkeyCombo, HotkeyRegistrationError> {
        guard combo.isRegistrable else { return .failure(.invalidCombo(combo.string)) }

        lock.lock()
        let duplicated = idByCombo[combo] != nil
        let id = nextID
        if !duplicated { nextID += 1 }
        lock.unlock()
        if duplicated { return .failure(.duplicateCombo(combo.string)) }

        if let status = installEventHandlerIfNeeded() {
            return .failure(.systemRejected(combo: combo.string, status: status))
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers.carbonMask,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return .failure(.systemRejected(combo: combo.string, status: status))
        }

        lock.lock()
        entries[id] = Entry(combo: combo, ref: ref, handler: handler)
        idByCombo[combo] = id
        lock.unlock()
        return .success(combo)
    }

    public func unregister(_ combo: HotkeyCombo) {
        lock.lock()
        guard let id = idByCombo.removeValue(forKey: combo),
              let entry = entries.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        UnregisterEventHotKey(entry.ref)
    }

    public func unregisterAll() {
        lock.lock()
        let all = entries
        entries.removeAll()
        idByCombo.removeAll()
        lock.unlock()
        for entry in all.values {
            UnregisterEventHotKey(entry.ref)
        }
    }

    /// 摘掉热键并移除 Carbon 事件处理器；之后再注册会重新安装。
    public func shutdown() {
        teardown()
    }

    private func teardown() {
        unregisterAll()
        lock.lock()
        let handler = eventHandler
        eventHandler = nil
        lock.unlock()
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    /// 由 Carbon 回调（主 run loop）触发；再显式切到主队列，UI 侧无需关心线程。
    fileprivate func dispatch(id: UInt32) {
        lock.lock()
        let entry = entries[id]
        lock.unlock()
        guard let entry else { return }
        let combo = entry.combo
        let handler = entry.handler
        DispatchQueue.main.async { handler(combo) }
    }

    /// 返回 nil 表示已就绪；返回 OSStatus 表示安装失败。
    private func installEventHandlerIfNeeded() -> OSStatus? {
        lock.lock()
        let existing = eventHandler
        lock.unlock()
        if existing != nil { return nil }

        var spec = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return err }
                let registry = Unmanaged<HotkeyRegistry>.fromOpaque(userData).takeUnretainedValue()
                registry.dispatch(id: hotKeyID.id)
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else { return status }
        lock.lock()
        eventHandler = handler
        lock.unlock()
        return nil
    }
}
