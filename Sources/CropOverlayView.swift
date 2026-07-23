import AppKit

/// A transparent capture layer placed over the video preview. While active,
/// drag to draw a crop marquee; on release it reports the box as a
/// NormalizedRect (top-left origin, 0...1) through `onCropChanged`. The
/// committed box is drawn as a persistent accent outline with the surrounding
/// area dimmed, and survives the overlay being deactivated. When inactive the
/// view is click-through, so the AVPlayerView's own transport controls beneath
/// it stay fully usable. Modeled on PdfRedactOverlayView.

final class CropOverlayView: NSView {
    /// The video's pixel size, so a drawn box can be mapped against the
    /// letterboxed display rect (AVPlayerView draws `.resizeAspect`).
    var contentSize: PixelSize?
    /// Reports the committed crop, or nil after Clear.
    var onCropChanged: ((NormalizedRect?) -> Void)?
    /// Escape while drawing asks the owner to leave crop mode.
    var onExit: (() -> Void)?

    /// Whether drawing is armed. Off = click-through so player controls work.
    var isActive = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            updateVisibility()
            needsDisplay = true
        }
    }

    /// The last committed crop, drawn persistently. Nil = none.
    var committedCrop: NormalizedRect? {
        didSet { updateVisibility(); needsDisplay = true }
    }

    /// Ignore drags smaller than this (view points), matching the pixel-space
    /// minimum in Geometry.normalizedCrop.
    private static let minPoints: CGFloat = 4

    private var startInSelf: NSPoint?
    private var currentInSelf: NSPoint?

    override var isFlipped: Bool { false }   // bottom-left origin, like the fit math
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isActive { addCursorRect(bounds, cursor: .crosshair) }
    }

    /// Click-through when not drawing, so the player controls underneath stay
    /// usable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive ? super.hitTest(point) : nil
    }

    private func updateVisibility() {
        isHidden = !isActive && committedCrop == nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        let point = convert(event.locationInWindow, from: nil)
        startInSelf = point
        currentInSelf = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isActive else { return }
        currentInSelf = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startInSelf = nil
            currentInSelf = nil
            needsDisplay = true
        }
        guard isActive, let content = contentSize,
              let start = startInSelf, let end = currentInSelf else { return }
        let fit = Geometry.aspectFitFrame(content: content,
                                          containerWidth: Double(bounds.width),
                                          containerHeight: Double(bounds.height))
        // A stray click (nil) keeps the previous crop; a real drag replaces it.
        guard let normalized = Geometry.normalizedCrop(
            from: (Double(start.x), Double(start.y)),
            to: (Double(end.x), Double(end.y)),
            fit: fit, minPoints: Double(Self.minPoints)) else { return }
        committedCrop = normalized
        onCropChanged?(normalized)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit?() }   // Escape
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Live drag rectangle takes precedence over the persisted outline.
        if let start = startInSelf, let current = currentInSelf {
            drawBox(NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                           width: abs(start.x - current.x),
                           height: abs(start.y - current.y)), dimOutside: false)
            return
        }
        guard let crop = committedCrop, let content = contentSize else { return }
        let fit = Geometry.aspectFitFrame(content: content,
                                          containerWidth: Double(bounds.width),
                                          containerHeight: Double(bounds.height))
        drawBox(viewRect(for: crop, fit: fit), dimOutside: true)
    }

    private func drawBox(_ rect: NSRect, dimOutside: Bool) {
        if dimOutside {
            let mask = NSBezierPath(rect: bounds)
            mask.append(NSBezierPath(rect: rect))
            mask.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.35).setFill()
            mask.fill()
        } else {
            NSColor.black.withAlphaComponent(0.25).setFill()
            rect.fill()
        }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 2
        outline.stroke()
    }

    /// Map a normalized (top-left) crop back to a bottom-left view rect.
    private func viewRect(for crop: NormalizedRect,
                          fit: (x: Double, y: Double, width: Double, height: Double)) -> NSRect {
        let width = crop.width * fit.width
        let height = crop.height * fit.height
        let x = fit.x + crop.x * fit.width
        // Flip Y back: normalized y is measured from the top edge.
        let y = fit.y + (1.0 - crop.y - crop.height) * fit.height
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
