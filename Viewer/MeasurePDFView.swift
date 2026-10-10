import AppKit
import PDFKit

/// A PDFView where, while `drawingEnabled`, dragging draws a straight line (in page coordinates)
/// instead of selecting text, and a click without dragging reports the click position.
/// Otherwise it behaves like a normal PDFView. Scrolling and zooming always work.
final class MeasurePDFView: PDFView {
    var drawingEnabled = false
    /// Called with the finished line. Holding Shift constrains it to multiples of 45°.
    var onLine: ((_ page: PDFPage, _ start: CGPoint, _ end: CGPoint) -> Void)?
    /// Called for a click without dragging, with the maximum hit distance in page points.
    var onClick: ((_ page: PDFPage, _ point: CGPoint, _ tolerance: CGFloat) -> Void)?
    var onDelete: (() -> Void)?
    var lineColor: NSColor = .systemRed

    private var dragPage: PDFPage?
    private var dragStart: CGPoint = .zero
    private var dragStartInView: CGPoint = .zero
    private var isDrawing = false
    private var previewAnnotation: PDFAnnotation?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard drawingEnabled else { return super.mouseDown(with: event) }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return }
        window?.makeFirstResponder(self)
        dragPage = page
        dragStart = convert(viewPoint, to: page)
        dragStartInView = viewPoint
        isDrawing = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawingEnabled else { return super.mouseDragged(with: event) }
        guard let page = dragPage else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if !isDrawing {
            guard hypot(viewPoint.x - dragStartInView.x, viewPoint.y - dragStartInView.y) > 3 else { return }
            isDrawing = true
        }
        let end = constrained(convert(viewPoint, to: page), shift: event.modifierFlags.contains(.shift))
        showPreview(on: page, from: dragStart, to: end)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard drawingEnabled else { return super.mouseUp(with: event) }
        guard let page = dragPage else { return }
        defer { dragPage = nil; isDrawing = false }
        removePreview()
        let viewPoint = convert(event.locationInWindow, from: nil)
        if isDrawing {
            let end = constrained(convert(viewPoint, to: page), shift: event.modifierFlags.contains(.shift))
            if hypot(end.x - dragStart.x, end.y - dragStart.y) > 0.5 {
                onLine?(page, dragStart, end)
            }
        } else {
            onClick?(page, dragStart, 6 / max(scaleFactor, 0.01))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if drawingEnabled { NSCursor.crosshair.set() }
    }

    override func keyDown(with event: NSEvent) {
        // Delete / forward delete remove the selected measurement.
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Helpers

    /// With Shift, snaps the line from `dragStart` to the nearest multiple of 45°.
    private func constrained(_ end: CGPoint, shift: Bool) -> CGPoint {
        guard shift else { return end }
        let dx = end.x - dragStart.x, dy = end.y - dragStart.y
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let length = dx * cos(angle) + dy * sin(angle)
        return CGPoint(x: dragStart.x + length * cos(angle), y: dragStart.y + length * sin(angle))
    }

    private func showPreview(on page: PDFPage, from start: CGPoint, to end: CGPoint) {
        removePreview()
        let annotation = Self.lineAnnotation(from: start, to: end, color: lineColor, width: 1.5 / max(scaleFactor, 0.01))
        page.addAnnotation(annotation)
        previewAnnotation = annotation
    }

    private func removePreview() {
        if let annotation = previewAnnotation {
            annotation.page?.removeAnnotation(annotation)
            previewAnnotation = nil
        }
    }

    /// A line annotation between two page points. PDFKit stores the end points relative to the
    /// annotation's bounds origin.
    static func lineAnnotation(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat,
                               arrows: Bool = false) -> PDFAnnotation {
        let pad = max(width * 4, 4)
        let bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -pad, dy: -pad)
        let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
        annotation.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
        annotation.color = color
        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        if arrows {
            annotation.startLineStyle = .closedArrow
            annotation.endLineStyle = .closedArrow
            annotation.interiorColor = color
        }
        annotation.isReadOnly = true
        return annotation
    }
}
