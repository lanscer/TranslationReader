import Foundation
import CoreGraphics

/// 文档 §6.1 冻结的选区结构。
public struct Selection: Hashable, Sendable {
    public let text: String
    /// 屏幕坐标系（AppKit，左下原点）下的选区包围盒。
    public let bounds: CGRect
    public let appBundleID: String
    public let isSecure: Bool

    public init(text: String, bounds: CGRect, appBundleID: String, isSecure: Bool = false) {
        self.text = text
        self.bounds = bounds
        self.appBundleID = appBundleID
        self.isSecure = isSecure
    }
}

/// 文档 §6.1 冻结的选区读取协议。AX 主路径与 ⌘C 兜底都由 SelectionKit 实现。
public protocol SelectionReading: AnyObject {
    func currentSelection() async -> Selection?
}
