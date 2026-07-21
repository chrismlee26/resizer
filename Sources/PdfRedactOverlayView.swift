import AppKit
import PDFKit

/// A transparent capture layer placed over the PDFView while redaction mode is
/// on. Drag to draw a marquee; on release it reports a rectangle in the page's
/// (unrotated) coordinate space — the same space PdfEditModel stores and
/// PdfAssembler bakes in at export. Removed from the view hierarchy when mode
/// is off, so normal PDFView interaction is untouched.

final class PdfRedactOverlayView: NSView {
    weak var pdfView: PDFView?
    /// Reports a finished box: the page it belongs to and its rect in page space.
    var onRedact: ((PDFPage, CGRect) -> Void)?
    var onExit: (() -> Void)?

    /// Ignore drags smaller than this (page points) so a stray click on the
    /// page does not drop a speck of a redaction.
    private static let minSize: CGFloat = 4

    private var startInSelf: NSPoint?
    private var currentInSelf: NSPoint?
    private var dragPage: PDFPage?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let pdfView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pdfPoint = pdfView.convert(point, from: self)
        dragPage = pdfView.page(for: pdfPoint, nearest: true)
        startInSelf = point
        currentInSelf = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentInSelf = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startInSelf = nil
            currentInSelf = nil
            dragPage = nil
            needsDisplay = true
        }
        guard let pdfView, let page = dragPage,
              let start = startInSelf, let end = currentInSelf else { return }

        // Convert both corners through the PDFView into the page's own space,
        // then normalize and clamp to the page.
        let a = pdfView.convert(pdfView.convert(start, from: self), to: page)
        let b = pdfView.convert(pdfView.convert(end, from: self), to: page)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
            .intersection(page.bounds(for: .mediaBox))

        guard !rect.isNull, rect.width >= Self.minSize, rect.height >= Self.minSize else { return }
        onRedact?(page, rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit?() }   // Escape
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let start = startInSelf, let current = currentInSelf else { return }
        let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(start.x - current.x), height: abs(start.y - current.y))
        NSColor.black.withAlphaComponent(0.35).setFill()
        rect.fill()
        NSColor.black.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()
    }
}
