import AppKit

/// A single-track slider with two draggable handles selecting a time range.
/// AppKit has no native range slider, so this draws a track with the
/// selected span highlighted in the accent color and a round knob at each
/// end. Dragging reports continuously through `onChanged`, including which
/// handle moved (so the preview can seek to that handle's frame).
final class TrimRangeSlider: NSView {
    enum Handle {
        case start
        case end
    }

    /// Fired continuously while dragging.
    var onChanged: ((Handle) -> Void)?

    var minValue: Double = 0
    var maxValue: Double = 1 { didSet { needsDisplay = true } }
    var startValue: Double = 0 { didSet { needsDisplay = true } }
    var endValue: Double = 1 { didSet { needsDisplay = true } }
    /// Smallest allowed span between the handles, in value units.
    var minimumGap: Double = 0.1
    var isEnabled = false { didSet { needsDisplay = true } }

    private var draggedHandle: Handle?

    private static let knobRadius: CGFloat = 7
    private static let trackHeight: CGFloat = 4

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.knobRadius * 2 + 4)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect()
        let radius = Self.trackHeight / 2

        let trackColor: NSColor = isEnabled ? .separatorColor : .quaternaryLabelColor
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let startX = xPosition(for: startValue)
        let endX = xPosition(for: endValue)
        let selected = NSRect(x: startX, y: track.minY,
                              width: max(endX - startX, 0), height: track.height)
        let fillColor: NSColor = isEnabled ? .controlAccentColor : .tertiaryLabelColor
        fillColor.setFill()
        NSBezierPath(roundedRect: selected, xRadius: radius, yRadius: radius).fill()

        drawKnob(at: startX)
        drawKnob(at: endX)
    }

    private func drawKnob(at x: CGFloat) {
        let rect = knobRect(at: x)
        let knob = NSBezierPath(ovalIn: rect)
        (isEnabled ? NSColor.controlColor : .quaternaryLabelColor).setFill()
        knob.fill()
        NSColor.tertiaryLabelColor.setStroke()
        knob.lineWidth = 0.5
        knob.stroke()
        if isEnabled {
            // Subtle shadowed look matching NSSlider knobs.
            let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor.white.withAlphaComponent(0.15).setFill()
            inner.fill()
        }
    }

    // MARK: - Geometry

    private func trackRect() -> NSRect {
        NSRect(x: Self.knobRadius,
               y: (bounds.height - Self.trackHeight) / 2,
               width: bounds.width - Self.knobRadius * 2,
               height: Self.trackHeight)
    }

    private func knobRect(at x: CGFloat) -> NSRect {
        NSRect(x: x - Self.knobRadius,
               y: bounds.height / 2 - Self.knobRadius,
               width: Self.knobRadius * 2, height: Self.knobRadius * 2)
    }

    private func xPosition(for value: Double) -> CGFloat {
        let track = trackRect()
        let span = max(maxValue - minValue, .ulpOfOne)
        let fraction = (value - minValue) / span
        return track.minX + track.width * CGFloat(min(max(fraction, 0), 1))
    }

    private func value(atX x: CGFloat) -> Double {
        let track = trackRect()
        guard track.width > 0 else { return minValue }
        let fraction = Double((x - track.minX) / track.width)
        return minValue + (maxValue - minValue) * min(max(fraction, 0), 1)
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let x = convert(event.locationInWindow, from: nil).x
        draggedHandle = nearestHandle(toX: x)
        drag(toX: x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, draggedHandle != nil else { return }
        drag(toX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        draggedHandle = nil
    }

    /// The handle closest to the click; when they overlap, clicking left of
    /// the pair grabs start and right of it grabs end, so a fully collapsed
    /// range stays operable.
    private func nearestHandle(toX x: CGFloat) -> Handle {
        let startX = xPosition(for: startValue)
        let endX = xPosition(for: endValue)
        if abs(x - startX) < abs(x - endX) { return .start }
        if abs(x - startX) > abs(x - endX) { return .end }
        return x < startX ? .start : .end
    }

    private func drag(toX x: CGFloat) {
        guard let handle = draggedHandle else { return }
        let raw = value(atX: x)
        switch handle {
        case .start:
            startValue = min(max(raw, minValue), endValue - minimumGap)
        case .end:
            endValue = max(min(raw, maxValue), startValue + minimumGap)
        }
        onChanged?(handle)
    }
}
