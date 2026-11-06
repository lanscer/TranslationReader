import Foundation
import AppKit
import CoreGraphics

/// 遮罩窗内容视图：拖框、尺寸提示、十字辅助线、Esc/空格。
/// 视图坐标 = 显示器内点坐标（左上原点、Y 向下），因此选中矩形可直接作为 SCK sourceRect。
final class SelectorView: NSView {

    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onFullScreen: (() -> Void)?
    var pixelScale: CGFloat = 2

    private(set) var dragOrigin: CGPoint?
    private(set) var dragCurrent: CGPoint?
    private var mouseLocation: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// 选中矩形（视图坐标，已规范化、非负宽高）。
    var selectionRect: CGRect {
        guard let origin = dragOrigin, let current = dragCurrent else { return .zero }
        return CGRect(x: min(origin.x, current.x),
                      y: min(origin.y, current.y),
                      width: abs(current.x - origin.x),
                      height: abs(current.y - origin.y))
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        dragCurrent = mouseLocation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        let rect = selectionRect
        dragOrigin = nil
        dragCurrent = nil
        needsDisplay = true
        // 拖拽太小视为误触，留在选择态让用户重试。
        guard rect.width >= 3, rect.height >= 3 else { return }
        onFinish?(rect.intersection(bounds))
    }

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()            // Esc
        case 49: onFullScreen?()        // Space
        default: super.keyDown(with: event)
        }
    }

    func clearDrag() {
        dragOrigin = nil
        dragCurrent = nil
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let rect = selectionRect
        let mask = NSBezierPath(rect: bounds)
        if rect.width > 0, rect.height > 0 {
            mask.append(NSBezierPath(rect: rect))
            mask.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.32).setFill()
        mask.fill()

        if rect.width > 0, rect.height > 0 {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1.5
            border.stroke()
            drawSizeHint(for: rect)
        } else if let mouse = mouseLocation {
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let guide = NSBezierPath()
            guide.move(to: CGPoint(x: bounds.minX, y: mouse.y))
            guide.line(to: CGPoint(x: bounds.maxX, y: mouse.y))
            guide.move(to: CGPoint(x: mouse.x, y: bounds.minY))
            guide.line(to: CGPoint(x: mouse.x, y: bounds.maxY))
            guide.lineWidth = 0.5
            guide.stroke()
        }

        drawInstructions()
    }

    private func drawSizeHint(for rect: CGRect) {
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        let widthPx = Int((rect.width * pixelScale).rounded())
        let heightPx = Int((rect.height * pixelScale).rounded())
        let text = widthPx == width ? "\(width) × \(height)" : "\(width) × \(height)  ·  \(widthPx) × \(heightPx) px"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 4)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        // 靠近屏幕边缘时把提示翻到框内，避免被裁掉。
        if origin.y + textSize.height + padding.height * 2 > bounds.maxY {
            origin.y = max(bounds.minY + 2, rect.maxY - textSize.height - padding.height * 2 - 6)
        }
        if origin.x + textSize.width + padding.width * 2 > bounds.maxX {
            origin.x = max(bounds.minX + 2, bounds.maxX - textSize.width - padding.width * 2 - 2)
        }
        let background = CGRect(x: origin.x, y: origin.y,
                                width: textSize.width + padding.width * 2,
                                height: textSize.height + padding.height * 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: background.minX + padding.width, y: background.minY + padding.height),
                  withAttributes: attributes)
    }

    private func drawInstructions() {
        let text = "拖动选择区域   ·   空格全屏   ·   Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let textSize = text.size(withAttributes: attributes)
        let background = CGRect(x: bounds.midX - textSize.width / 2 - 14,
                                y: bounds.minY + 36,
                                width: textSize.width + 28,
                                height: textSize.height + 12)
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: background, xRadius: 9, yRadius: 9).fill()
        text.draw(at: CGPoint(x: background.minX + 14, y: background.minY + 6), withAttributes: attributes)
    }

    // MARK: - 预览（无录屏权限时的 UI 自检）

    func configureForPreview(selection: CGRect, mouse: CGPoint?) {
        dragOrigin = CGPoint(x: selection.minX, y: selection.minY)
        dragCurrent = CGPoint(x: selection.maxX, y: selection.maxY)
        mouseLocation = mouse
    }
}
