import Foundation

/// Pure sizing math — no I/O, fully unit-testable.

struct PixelSize: Equatable {
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
