import AppKit
import ApplicationServices
import Contracts

/// 文档 §6.1 主路径：AXUIElementCreateSystemWide → kAXFocusedUIElementAttribute
/// → kAXSelectedTextAttribute（取文）+ kAXSelectedTextRangeAttribute / kAXBoundsForRange（取包围盒）。
public struct AXSelectionReader {
    public let gate: SelectionGate
    public let log: SelectionLogSink

    public init(gate: SelectionGate = SelectionGate(), log: @escaping SelectionLogSink = SelectionLog.defaultSink) {
        self.gate = gate
        self.log = log
    }

    public func currentSelection() -> Selection? {
        guard gate.enabled else {
            log("ax: 跳过（取词已禁用）")
            return nil
        }
        guard AXIsProcessTrusted() else {
            log("ax: 未获辅助功能授权，跳过 AX 主路径")
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        guard let element: AXUIElement = Self.copyAttribute(systemWide, kAXFocusedUIElementAttribute as CFString) else {
            log("ax: 无聚焦元素（kAXFocusedUIElementAttribute 读取失败）")
            return nil
        }

        let role = Self.stringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = Self.stringAttribute(element, kAXSubroleAttribute as CFString)
        let isSecureStyle = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        let bundleID = Self.bundleIdentifier(of: element)

        if isSecureStyle {
            log("ax: 密码框 role=\(role ?? "nil") subrole=\(subrole ?? "nil")，不读")
        }
        if let reason = gate.preflight(bundleID: bundleID, isSecure: isSecureStyle) {
            log("ax: 隐私闸门拦截 \(reason.rawValue) bundle=\(bundleID ?? "nil")")
            return nil
        }

        guard let text: String = Self.copyAttribute(element, kAXSelectedTextAttribute as CFString) else {
            log("ax: 控件不支持 kAXSelectedTextAttribute，回落兜底")
            return nil
        }
        if let reason = gate.validate(text: text) {
            log("ax: 文本闸门拦截 \(reason.rawValue) len=\(text.count)")
            return nil
        }

        let axBounds = Self.selectedBounds(element: element)
        let bounds: CGRect
        if let axBounds {
            bounds = AXGeometry.appKitRect(fromAX: axBounds, primaryScreenHeight: Self.primaryScreenHeight())
        } else {
            log("ax: 无选区包围盒，退化为鼠标位置锚点")
            bounds = CGRect(origin: NSEvent.mouseLocation, size: .zero)
        }
        log("ax: 命中 bundle=\(bundleID ?? "nil") len=\(text.count) axRect=\(Self.describe(axBounds)) appKitRect=\(Self.describe(bounds))")
        return Selection(text: text, bounds: bounds, appBundleID: bundleID ?? "", isSecure: false)
    }

    // MARK: - AX 辅助

    /// 主屏高度（AX 全局坐标的翻转基准）。
    public static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func bundleIdentifier(of element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    static func copyAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else { return nil }
        return value as? T
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        copyAttribute(element, attribute)
    }

    static func axValue(_ raw: CFTypeRef?) -> AXValue? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXValue.self)
    }

    /// 选区包围盒：kAXSelectedTextRangeAttribute → kAXBoundsForRangeParameterizedAttribute。
    /// 控件不支持参数化属性时，退化为整个控件的 kAXPosition/kAXSize。
    static func selectedBounds(element: AXUIElement) -> CGRect? {
        guard let rangeRaw: CFTypeRef = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString),
              let rangeValue = axValue(rangeRaw) else {
            return elementBounds(element)
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.length > 0 else {
            return elementBounds(element)
        }

        var boundsRaw: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRaw
        )
        guard status == .success, let boundsValue = axValue(boundsRaw) else {
            return elementBounds(element)
        }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect) else {
            return elementBounds(element)
        }
        return rect
    }

    static func elementBounds(_ element: AXUIElement) -> CGRect? {
        guard let positionRaw: CFTypeRef = copyAttribute(element, kAXPositionAttribute as CFString),
              let sizeRaw: CFTypeRef = copyAttribute(element, kAXSizeAttribute as CFString),
              let positionValue = axValue(positionRaw),
              let sizeValue = axValue(sizeRaw) else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "(%.1f,%.1f %.1fx%.1f)",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
        )
    }
}
