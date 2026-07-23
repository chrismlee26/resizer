import Foundation

/// Pure sizing math — no I/O, fully unit-testable.

struct PixelSize: Equatable {
    let width: Int
    let height: Int
}

/// A crop region expressed as fractions of the video frame: top-left origin,
/// every field in 0...1. Stored by the UI so it survives preview relayout;
/// converted to source pixels only at export time.
struct NormalizedRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// A crop region in source pixels: top-left origin, matching ffmpeg's
/// `crop=w:h:x:y` filter. width/height are the exact output dimensions — a
/// crop is exported at native resolution, never scaled.
struct CropRect: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

enum ResizeMode: Equatable {
    case percent(Double)        // 0 < p, e.g. 50.0 for half size
    case fit(PixelSize)         // fit within box, preserve aspect
    case exact(PixelSize)       // exact dimensions, may distort
}

enum Geometry {
    /// Compute the output size for a source image under a resize mode.
    /// Result is always at least 1x1.
    static func targetSize(source: PixelSize, mode: ResizeMode) -> PixelSize {
        switch mode {
        case .percent(let p):
            let scale = max(p, 0.01) / 100.0
            return clamped(width: Double(source.width) * scale,
                           height: Double(source.height) * scale)
        case .fit(let box):
            let scale = min(Double(box.width) / Double(source.width),
                            Double(box.height) / Double(source.height))
            return clamped(width: Double(source.width) * scale,
                           height: Double(source.height) * scale)
        case .exact(let size):
            return PixelSize(width: max(size.width, 1), height: max(size.height, 1))
        }
    }

    /// Given a GIF that came out `actualBytes` at `currentWidth`, pick the next
    /// smaller width to try so the result lands under `targetBytes`.
    /// GIF size scales roughly with pixel area, so scale width by sqrt of the
    /// byte ratio, with a 10% safety margin. Returns nil when there is no
    /// useful reduction left.
    static func nextGifWidth(currentWidth: Int, actualBytes: Int, targetBytes: Int) -> Int? {
        guard actualBytes > targetBytes, currentWidth > 40 else { return nil }
        let ratio = (Double(targetBytes) / Double(actualBytes)) * 0.9
        var next = Int(Double(currentWidth) * ratio.squareRoot())
        next -= next % 2  // ffmpeg-friendly even width
        // Always shrink by at least 10% so the loop cannot stall.
        next = min(next, Int(Double(currentWidth) * 0.9))
        return next >= 40 ? next : 40
    }

    /// Build a never-colliding output URL: "name-suffix-<token>.ext" where
    /// token is random, so an output can never replace an existing file.
    /// `exists` and `tokenGenerator` are injected for testability.
    static func outputURL(for source: URL, suffix: String, ext: String,
                          tokenGenerator: () -> String = { randomToken() },
                          exists: (URL) -> Bool) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        for _ in 0..<32 {
            let candidate = dir.appendingPathComponent("\(base)-\(suffix)-\(tokenGenerator()).\(ext)")
            if !exists(candidate) { return candidate }
        }
        // Pathological fallback (e.g. a stuck token generator): counter names.
        var counter = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base)-\(suffix)-\(counter).\(ext)")
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }

    /// Validate a requested trim range against the clip duration.
    /// Returns clamped absolute times, or nil when the trim is a no-op:
    /// unset, inverted, shorter than 0.1 s, or covering (nearly) the whole
    /// clip — so a full-range "trim" emits no ffmpeg seek args at all.
    static func clampedTrim(start: Double?, end: Double?,
                            duration: Double) -> (start: Double, end: Double)? {
        guard duration > 0, start != nil || end != nil else { return nil }
        let epsilon = 0.05
        let clampedStart = min(max(start ?? 0, 0), duration)
        let clampedEnd = min(max(end ?? duration, 0), duration)
        guard clampedEnd - clampedStart >= 0.1 else { return nil }
        if clampedStart <= epsilon && clampedEnd >= duration - epsilon { return nil }
        return (clampedStart, clampedEnd)
    }

    /// Map a log2 speed-slider position (-2...2, where 0 = normal) to an
    /// export-speed percent: 100 × 2^v, clamped to 25...400 and rounded to
    /// the nearest 5. So the slider's five ticks land on 25/50/100/200/400
    /// and 100% sits dead centre.
    static func speedPercent(sliderValue: Double) -> Int {
        let raw = 100.0 * pow(2.0, sliderValue)
        let clamped = min(max(raw, 25), 400)
        return Int((clamped / 5).rounded()) * 5
    }

    /// Validate an export-speed percent. Returns nil for the no-op case
    /// (within 2.5% of 100, or non-positive) so exporting at 100% emits no
    /// setpts filter at all; otherwise the playback multiplier percent/100
    /// clamped to 0.25...4.0.
    static func speedFactor(percent: Double) -> Double? {
        guard percent > 0, abs(percent - 100) >= 2.5 else { return nil }
        return min(max(percent / 100.0, 0.25), 4.0)
    }

    /// Where an aspect-fit (`.resizeAspect`) render of `content` lands inside
    /// a container, in bottom-left view coordinates. This reproduces where an
    /// AVPlayerView actually draws the video (letterbox/pillarbox bars are the
    /// leftover space), so a box drawn over the view can be mapped back to the
    /// frame. Returns the full container for degenerate inputs.
    static func aspectFitFrame(content: PixelSize,
                               containerWidth: Double,
                               containerHeight: Double)
        -> (x: Double, y: Double, width: Double, height: Double) {
        guard content.width > 0, content.height > 0,
              containerWidth > 0, containerHeight > 0 else {
            return (0, 0, max(containerWidth, 0), max(containerHeight, 0))
        }
        let scale = min(containerWidth / Double(content.width),
                        containerHeight / Double(content.height))
        let w = Double(content.width) * scale
        let h = Double(content.height) * scale
        return ((containerWidth - w) / 2, (containerHeight - h) / 2, w, h)
    }

    /// Normalize a drag (two corners in bottom-left view coords) against the
    /// displayed video's `fit` frame: order the corners, intersect with the
    /// fit frame, flip Y to a top-left origin, and divide by the fit size.
    /// Returns nil when the intersection is under `minPoints` in either axis —
    /// a stray click, or a drag lying entirely in a letterbox bar.
    static func normalizedCrop(from a: (x: Double, y: Double),
                               to b: (x: Double, y: Double),
                               fit: (x: Double, y: Double, width: Double, height: Double),
                               minPoints: Double = 4) -> NormalizedRect? {
        guard fit.width > 0, fit.height > 0 else { return nil }
        let left = max(min(a.x, b.x), fit.x)
        let right = min(max(a.x, b.x), fit.x + fit.width)
        let bottom = max(min(a.y, b.y), fit.y)
        let top = min(max(a.y, b.y), fit.y + fit.height)
        let w = right - left
        let h = top - bottom
        guard w >= minPoints, h >= minPoints else { return nil }
        let nx = (left - fit.x) / fit.width
        let nw = w / fit.width
        let nh = h / fit.height
        // View y grows upward; crop y grows downward from the top edge.
        let ny = 1.0 - (bottom - fit.y) / fit.height - nh
        return NormalizedRect(x: nx, y: ny, width: nw, height: nh)
    }

    /// Convert a normalized crop to integer source pixels: scale by the source
    /// size, round, force even width/height (safe encoder input), and clamp so
    /// the rect stays fully inside the frame. Returns nil when the result is
    /// under `minPixels` in either axis or covers essentially the whole frame
    /// (within 1% of every edge) — mirroring clampedTrim's no-op contract. The
    /// returned width/height ARE the exported dimensions (a crop is not scaled).
    static func pixelCrop(_ crop: NormalizedRect, in source: PixelSize,
                          minPixels: Int = 16) -> CropRect? {
        guard source.width > 0, source.height > 0 else { return nil }
        let epsilon = 0.01
        if crop.x <= epsilon, crop.y <= epsilon,
           crop.x + crop.width >= 1 - epsilon,
           crop.y + crop.height >= 1 - epsilon { return nil }

        let sw = Double(source.width), sh = Double(source.height)
        var w = Int((crop.width * sw).rounded())
        var h = Int((crop.height * sh).rounded())
        w -= w % 2
        h -= h % 2
        guard w >= minPixels, h >= minPixels else { return nil }
        let x = min(max(Int((crop.x * sw).rounded()), 0), source.width - w)
        let y = min(max(Int((crop.y * sh).rounded()), 0), source.height - h)
        return CropRect(x: x, y: y, width: w, height: h)
    }

    /// Short random token for output names. Ambiguous characters excluded.
    static func randomToken(length: Int = 4) -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func clamped(width: Double, height: Double) -> PixelSize {
        PixelSize(width: max(Int(width.rounded()), 1),
                  height: max(Int(height.rounded()), 1))
    }
}
