import AppKit
import Carbon

/// 文档 §7：全局热键走 Carbon `RegisterEventHotKey`，不需要任何 TCC 权限
/// （NSEvent 全局监听才需要「输入监控」；本模块只有录制用本地监听）。
public struct HotkeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)

    /// 规范化书写顺序 ⌃⌥⇧⌘，与 macOS 菜单里的符号顺序一致。
    static let ordered: [(HotkeyModifiers, String, String)] = [
        (.control, "ctrl", "⌃"),
        (.option, "opt", "⌥"),
        (.shift, "shift", "⇧"),
        (.command, "cmd", "⌘"),
    ]

    /// 解析单字符修饰键别名（"ctrl"/"⌘"/"alt"…），不是修饰键则返回 nil。
    public static func alias(_ token: String) -> HotkeyModifiers? {
        switch token.lowercased() {
        case "ctrl", "control", "^", "⌃": return .control
        case "opt", "option", "alt", "⌥": return .option
        case "shift", "⇧": return .shift
        case "cmd", "command", "meta", "super", "⌘": return .command
        default: return nil
        }
    }

    /// 单词形式，如 "ctrl+opt"。
    public var string: String {
        Self.ordered.filter { contains($0.0) }.map { $0.1 }.joined(separator: "+")
    }

    /// 符号形式，如 "⌃⌥"。
    public var symbols: String {
        Self.ordered.filter { contains($0.0) }.map { $0.2 }.joined()
    }

    /// Carbon 修饰位（cmdKey / optionKey / controlKey / shiftKey）。
    public var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= UInt32(cmdKey) }
        if contains(.option) { mask |= UInt32(optionKey) }
        if contains(.control) { mask |= UInt32(controlKey) }
        if contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    public init(carbonMask: UInt32) {
        var modifiers: HotkeyModifiers = []
        if carbonMask & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if carbonMask & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbonMask & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if carbonMask & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        self = modifiers
    }

    public init(nsFlags: NSEvent.ModifierFlags) {
        var modifiers: HotkeyModifiers = []
        if nsFlags.contains(.command) { modifiers.insert(.command) }
        if nsFlags.contains(.option) { modifiers.insert(.option) }
        if nsFlags.contains(.control) { modifiers.insert(.control) }
        if nsFlags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}

/// 单个主键：虚拟键码 + 规范化 token。等值只看键码，避免别名产生两份注册。
public struct HotkeyKey: Hashable, Sendable, CustomStringConvertible {
    public let keyCode: UInt32
    /// 规范化小写 token，如 "space"、"a"、"f1"、"return"。
    public let token: String
    /// 展示名，如 "Space"、"A"、"F1"、"↩"。
    public let display: String

    private struct Spec {
        let token: String
        let code: Int
        let aliases: [String]
        let display: String
    }

    private static let specs: [Spec] = [
        Spec(token: "a", code: kVK_ANSI_A, aliases: [], display: "A"),
        Spec(token: "b", code: kVK_ANSI_B, aliases: [], display: "B"),
        Spec(token: "c", code: kVK_ANSI_C, aliases: [], display: "C"),
        Spec(token: "d", code: kVK_ANSI_D, aliases: [], display: "D"),
        Spec(token: "e", code: kVK_ANSI_E, aliases: [], display: "E"),
        Spec(token: "f", code: kVK_ANSI_F, aliases: [], display: "F"),
        Spec(token: "g", code: kVK_ANSI_G, aliases: [], display: "G"),
        Spec(token: "h", code: kVK_ANSI_H, aliases: [], display: "H"),
        Spec(token: "i", code: kVK_ANSI_I, aliases: [], display: "I"),
        Spec(token: "j", code: kVK_ANSI_J, aliases: [], display: "J"),
        Spec(token: "k", code: kVK_ANSI_K, aliases: [], display: "K"),
        Spec(token: "l", code: kVK_ANSI_L, aliases: [], display: "L"),
        Spec(token: "m", code: kVK_ANSI_M, aliases: [], display: "M"),
        Spec(token: "n", code: kVK_ANSI_N, aliases: [], display: "N"),
        Spec(token: "o", code: kVK_ANSI_O, aliases: [], display: "O"),
        Spec(token: "p", code: kVK_ANSI_P, aliases: [], display: "P"),
        Spec(token: "q", code: kVK_ANSI_Q, aliases: [], display: "Q"),
        Spec(token: "r", code: kVK_ANSI_R, aliases: [], display: "R"),
        Spec(token: "s", code: kVK_ANSI_S, aliases: [], display: "S"),
        Spec(token: "t", code: kVK_ANSI_T, aliases: [], display: "T"),
        Spec(token: "u", code: kVK_ANSI_U, aliases: [], display: "U"),
        Spec(token: "v", code: kVK_ANSI_V, aliases: [], display: "V"),
        Spec(token: "w", code: kVK_ANSI_W, aliases: [], display: "W"),
        Spec(token: "x", code: kVK_ANSI_X, aliases: [], display: "X"),
        Spec(token: "y", code: kVK_ANSI_Y, aliases: [], display: "Y"),
        Spec(token: "z", code: kVK_ANSI_Z, aliases: [], display: "Z"),
        Spec(token: "0", code: kVK_ANSI_0, aliases: [], display: "0"),
        Spec(token: "1", code: kVK_ANSI_1, aliases: [], display: "1"),
        Spec(token: "2", code: kVK_ANSI_2, aliases: [], display: "2"),
        Spec(token: "3", code: kVK_ANSI_3, aliases: [], display: "3"),
        Spec(token: "4", code: kVK_ANSI_4, aliases: [], display: "4"),
        Spec(token: "5", code: kVK_ANSI_5, aliases: [], display: "5"),
        Spec(token: "6", code: kVK_ANSI_6, aliases: [], display: "6"),
        Spec(token: "7", code: kVK_ANSI_7, aliases: [], display: "7"),
        Spec(token: "8", code: kVK_ANSI_8, aliases: [], display: "8"),
        Spec(token: "9", code: kVK_ANSI_9, aliases: [], display: "9"),
        Spec(token: "space", code: kVK_Space, aliases: ["spacebar"], display: "Space"),
        Spec(token: "return", code: kVK_Return, aliases: ["enter"], display: "↩"),
        Spec(token: "tab", code: kVK_Tab, aliases: [], display: "⇥"),
        Spec(token: "escape", code: kVK_Escape, aliases: ["esc"], display: "⎋"),
        Spec(token: "delete", code: kVK_Delete, aliases: ["backspace"], display: "⌫"),
        Spec(token: "forwarddelete", code: kVK_ForwardDelete, aliases: ["fdel", "del"], display: "⌦"),
        Spec(token: "left", code: kVK_LeftArrow, aliases: ["leftarrow", "arrowleft"], display: "←"),
        Spec(token: "right", code: kVK_RightArrow, aliases: ["rightarrow", "arrowright"], display: "→"),
        Spec(token: "down", code: kVK_DownArrow, aliases: ["downarrow", "arrowdown"], display: "↓"),
        Spec(token: "up", code: kVK_UpArrow, aliases: ["uparrow", "arrowup"], display: "↑"),
        Spec(token: "home", code: kVK_Home, aliases: [], display: "↖"),
        Spec(token: "end", code: kVK_End, aliases: [], display: "↘"),
        Spec(token: "pageup", code: kVK_PageUp, aliases: ["pgup"], display: "⇞"),
        Spec(token: "pagedown", code: kVK_PageDown, aliases: ["pgdn"], display: "⇟"),
        Spec(token: "period", code: kVK_ANSI_Period, aliases: ["."], display: "."),
        Spec(token: "comma", code: kVK_ANSI_Comma, aliases: [","], display: ","),
        Spec(token: "slash", code: kVK_ANSI_Slash, aliases: ["/"], display: "/"),
        Spec(token: "backslash", code: kVK_ANSI_Backslash, aliases: ["\\"], display: "\\"),
        Spec(token: "semicolon", code: kVK_ANSI_Semicolon, aliases: [";"], display: ";"),
        Spec(token: "quote", code: kVK_ANSI_Quote, aliases: ["'"], display: "'"),
        Spec(token: "minus", code: kVK_ANSI_Minus, aliases: ["-"], display: "-"),
        Spec(token: "equal", code: kVK_ANSI_Equal, aliases: ["="], display: "="),
        Spec(token: "grave", code: kVK_ANSI_Grave, aliases: ["`"], display: "`"),
        Spec(token: "bracketleft", code: kVK_ANSI_LeftBracket, aliases: ["["], display: "["),
        Spec(token: "bracketright", code: kVK_ANSI_RightBracket, aliases: ["]"], display: "]"),
        Spec(token: "f1", code: kVK_F1, aliases: [], display: "F1"),
        Spec(token: "f2", code: kVK_F2, aliases: [], display: "F2"),
        Spec(token: "f3", code: kVK_F3, aliases: [], display: "F3"),
        Spec(token: "f4", code: kVK_F4, aliases: [], display: "F4"),
        Spec(token: "f5", code: kVK_F5, aliases: [], display: "F5"),
        Spec(token: "f6", code: kVK_F6, aliases: [], display: "F6"),
        Spec(token: "f7", code: kVK_F7, aliases: [], display: "F7"),
        Spec(token: "f8", code: kVK_F8, aliases: [], display: "F8"),
        Spec(token: "f9", code: kVK_F9, aliases: [], display: "F9"),
        Spec(token: "f10", code: kVK_F10, aliases: [], display: "F10"),
        Spec(token: "f11", code: kVK_F11, aliases: [], display: "F11"),
        Spec(token: "f12", code: kVK_F12, aliases: [], display: "F12"),
        Spec(token: "f13", code: kVK_F13, aliases: [], display: "F13"),
        Spec(token: "f14", code: kVK_F14, aliases: [], display: "F14"),
        Spec(token: "f15", code: kVK_F15, aliases: [], display: "F15"),
        Spec(token: "f16", code: kVK_F16, aliases: [], display: "F16"),
        Spec(token: "f17", code: kVK_F17, aliases: [], display: "F17"),
        Spec(token: "f18", code: kVK_F18, aliases: [], display: "F18"),
        Spec(token: "f19", code: kVK_F19, aliases: [], display: "F19"),
        Spec(token: "f20", code: kVK_F20, aliases: [], display: "F20"),
    ]

    private static let byToken: [String: Spec] = {
        var table: [String: Spec] = [:]
        for spec in specs {
            table[spec.token] = spec
            for alias in spec.aliases { table[alias] = spec }
        }
        return table
    }()

    private static let byCode: [UInt32: Spec] = {
        var table: [UInt32: Spec] = [:]
        for spec in specs { table[UInt32(spec.code)] = spec }
        return table
    }()

    public init?(token raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let spec = Self.byToken[key] else { return nil }
        self.keyCode = UInt32(spec.code)
        self.token = spec.token
        self.display = spec.display
    }

    public init?(keyCode: UInt32) {
        guard let spec = Self.byCode[keyCode] else { return nil }
        self.keyCode = keyCode
        self.token = spec.token
        self.display = spec.display
    }

    /// F1–F20：唯一允许不带修饰键注册的键（与系统习惯一致，避免吞掉普通输入）。
    public var isFunctionKey: Bool { token.hasPrefix("f") && UInt32(token.dropFirst()) != nil }

    public var description: String { token }
}

/// 一个完整的组合键：修饰键 + 主键。
public struct HotkeyCombo: Hashable, Sendable, CustomStringConvertible {
    public let modifiers: HotkeyModifiers
    public let key: HotkeyKey

    public init(modifiers: HotkeyModifiers, key: HotkeyKey) {
        self.modifiers = modifiers
        self.key = key
    }

    /// 从 NSEvent 键码转换（录制用）；未知键码返回 nil。
    public init?(keyCode: UInt32, modifiers: HotkeyModifiers) {
        guard let key = HotkeyKey(keyCode: keyCode) else { return nil }
        self.modifiers = modifiers
        self.key = key
    }

    /// 解析 "opt+space"、"cmd+shift+a"、"⌥Space"、"f5"；无法解析返回 nil。
    public init?(string raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("+") {
            let parts = trimmed.split(separator: "+").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count >= 2, let key = HotkeyKey(token: parts[parts.count - 1]) else { return nil }
            var modifiers: HotkeyModifiers = []
            for token in parts.dropLast() {
                guard let modifier = HotkeyModifiers.alias(token) else { return nil }
                modifiers.insert(modifier)
            }
            self.init(modifiers: modifiers, key: key)
            return
        }

        // 无加号的符号写法："⌥Space"、"⇧⌘A"。
        var rest = Substring(trimmed)
        var modifiers: HotkeyModifiers = []
        while let first = rest.first, let modifier = HotkeyModifiers.alias(String(first)) {
            modifiers.insert(modifier)
            rest = rest.dropFirst()
        }
        guard let key = HotkeyKey(token: String(rest)) else { return nil }
        self.init(modifiers: modifiers, key: key)
    }

    /// 规范化字符串（持久化 / 设置项格式），如 "opt+space"。
    public var string: String {
        let modifiers = self.modifiers.string
        return modifiers.isEmpty ? key.token : modifiers + "+" + key.token
    }

    /// 展示用字符串，如 "⌥Space"。
    public var displayString: String { modifiers.symbols + key.display }

    /// Carbon 注册用的虚拟键码。
    public var keyCode: UInt32 { key.keyCode }

    public var description: String { string }

    /// 带修饰键，或本身是功能键，才允许注册（防止裸字母吞掉用户输入）。
    public var isRegistrable: Bool { !modifiers.isEmpty || key.isFunctionKey }
}
