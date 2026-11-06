import Foundation
import Contracts

/// 文档 §3.1「不应出现的场景」的可测枚举。
public enum SelectionRejectReason: String, Sendable, Equatable, CustomStringConvertible {
    case disabled = "selection-disabled"
    case blockedApp = "blocklisted-app"
    case ownApp = "own-app"
    case secureField = "secure-field"
    case empty = "empty"
    case digitsOnly = "digits-only"
    case tooShort = "too-short"

    public var description: String { rawValue }
}

/// 取词闸门：禁用 / 密码框 / 黑名单 / 自身 / 空 / 纯数字 / 单字符，一律不弹浮条。
public struct SelectionGate: Sendable, Equatable {
    public var enabled: Bool
    public var blocklist: Set<String>
    public var ownBundleID: String?
    /// 文档 §3.1：单字符不出现浮条，所以默认门槛是 2 个字符。
    public var minimumCharacters: Int

    public init(
        enabled: Bool = true,
        blocklist: Set<String> = ["com.apple.Terminal", "com.apple.keychainaccess"],
        ownBundleID: String? = nil,
        minimumCharacters: Int = 2
    ) {
        self.enabled = enabled
        self.blocklist = blocklist
        self.ownBundleID = ownBundleID
        self.minimumCharacters = minimumCharacters
    }

    /// 文档 §6.7 设置树：开关与黑名单来自 AppSettings.selection。
    public init(settings: AppSettings, ownBundleID: String? = nil, minimumCharacters: Int = 2) {
        self.init(
            enabled: settings.selection.enabled,
            blocklist: Set(settings.selection.blocklist),
            ownBundleID: ownBundleID,
            minimumCharacters: minimumCharacters
        )
    }

    /// 读文本之前的闸门：禁用、密码框、黑名单、自身。
    public func preflight(bundleID: String?, isSecure: Bool) -> SelectionRejectReason? {
        guard enabled else { return .disabled }
        guard !isSecure else { return .secureField }
        if let bundleID {
            if let ownBundleID, !ownBundleID.isEmpty, bundleID == ownBundleID { return .ownApp }
            if blocklist.contains(bundleID) { return .blockedApp }
        }
        return nil
    }

    /// 读到文本之后的闸门：空、过短、纯数字。
    public func validate(text rawText: String) -> SelectionRejectReason? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        guard text.count >= max(minimumCharacters, 1) else { return .tooShort }
        guard !Self.isDigitsOnly(text) else { return .digitsOnly }
        return nil
    }

    public func evaluate(text: String, bundleID: String?, isSecure: Bool = false) -> SelectionRejectReason? {
        preflight(bundleID: bundleID, isSecure: isSecure) ?? validate(text: text)
    }

    /// 纯数字（允许千分位与百分号，忽略空白）视为无需翻译。
    public static func isDigitsOnly(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !scalars.isEmpty else { return false }
        return scalars.allSatisfy { scalar in
            CharacterSet.decimalDigits.contains(scalar)
                || scalar == ","
                || scalar == "."
                || scalar == "%"
                || scalar == "-"
                || scalar == "+"
        }
    }
}
