import Foundation

// Minimal assertion harness (no XCTest — this compiles with plain swiftc).
var failures = 0
func expect(_ condition: Bool, _ message: String,
            file: String = #file, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL [\(URL(fileURLWithPath: file).lastPathComponent):\(line)] \(message)")
    }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String,
                               file: String = #file, line: Int = #line) {
    expect(a == b, "\(message) — got \(a), expected \(b)", file: file, line: line)
}

// targetSize: percent
expectEqual(Geometry.targetSize(source: PixelSize(width: 1000, height: 500),
                                mode: .percent(50)),
            PixelSize(width: 500, height: 250), "50% halves both dimensions")
expectEqual(Geometry.targetSize(source: PixelSize(width: 3, height: 3),
                                mode: .percent(10)),
            PixelSize(width: 1, height: 1), "tiny percent clamps to >= 1px")
expectEqual(Geometry.targetSize(source: PixelSize(width: 100, height: 100),
                                mode: .percent(200)),
            PixelSize(width: 200, height: 200), "percent > 100 upscales")

// targetSize: fit
expectEqual(Geometry.targetSize(source: PixelSize(width: 4000, height: 3000),
                                mode: .fit(PixelSize(width: 1000, height: 1000))),
            PixelSize(width: 1000, height: 750), "fit preserves aspect, landscape")
expectEqual(Geometry.targetSize(source: PixelSize(width: 3000, height: 4000),
                                mode: .fit(PixelSize(width: 1000, height: 1000))),
            PixelSize(width: 750, height: 1000), "fit preserves aspect, portrait")
expectEqual(Geometry.targetSize(source: PixelSize(width: 500, height: 500),
                                mode: .fit(PixelSize(width: 1000, height: 1000))),
            PixelSize(width: 1000, height: 1000), "fit upscales to fill box")

// targetSize: exact
expectEqual(Geometry.targetSize(source: PixelSize(width: 4000, height: 3000),
                                mode: .exact(PixelSize(width: 640, height: 480))),
            PixelSize(width: 640, height: 480), "exact ignores aspect")

// nextGifWidth
expectEqual(Geometry.nextGifWidth(currentWidth: 640, actualBytes: 900_000,
                                  targetBytes: 1_000_000),
            nil, "already under target → nil")
if let next = Geometry.nextGifWidth(currentWidth: 640, actualBytes: 4_000_000,
                                    targetBytes: 1_000_000) {
    expect(next < 640, "next width shrinks (got \(next))")
    expect(next % 2 == 0, "next width is even (got \(next))")
    expect(next >= 40, "next width >= floor (got \(next))")
} else {
    expect(false, "expected a next width when over target")
}
expectEqual(Geometry.nextGifWidth(currentWidth: 40, actualBytes: 4_000_000,
                                  targetBytes: 1_000_000),
            nil, "at minimum width → nil (no infinite loop)")
if let next = Geometry.nextGifWidth(currentWidth: 640, actualBytes: 1_000_001,
                                    targetBytes: 1_000_000) {
    expect(next <= Int(640.0 * 0.9), "shrinks at least 10% even when barely over (got \(next))")
}

// outputURL: token naming and collision handling
let source = URL(fileURLWithPath: "/photos/cat.jpg")
let fresh = Geometry.outputURL(for: source, suffix: "800w",
                               ext: "jpg", tokenGenerator: { "abcd" }) { _ in false }
expectEqual(fresh.path, "/photos/cat-800w-abcd.jpg", "name is base-suffix-token.ext")

// Colliding token: a new token is drawn.
var tokens = ["abcd", "wxyz"]
let retried = Geometry.outputURL(for: source, suffix: "800w",
                                 ext: "jpg", tokenGenerator: { tokens.removeFirst() }) {
    $0.path == "/photos/cat-800w-abcd.jpg"
}
expectEqual(retried.path, "/photos/cat-800w-wxyz.jpg", "collision draws a new token")

// Stuck generator: falls back to counter names, never overwrites.
let stuck = Geometry.outputURL(for: source, suffix: "800w",
                               ext: "jpg", tokenGenerator: { "abcd" }) {
    $0.path == "/photos/cat-800w-abcd.jpg" || $0.path == "/photos/cat-800w-2.jpg"
}
expectEqual(stuck.path, "/photos/cat-800w-3.jpg", "stuck tokens fall back to counter")

// clampedTrim: no-op cases return nil
expect(Geometry.clampedTrim(start: nil, end: nil, duration: 10) == nil,
       "unset trim → nil")
expect(Geometry.clampedTrim(start: 0, end: 10, duration: 10) == nil,
       "full-range trim → nil")
expect(Geometry.clampedTrim(start: 0.04, end: 9.96, duration: 10) == nil,
       "near-full range (within epsilon) → nil")
expect(Geometry.clampedTrim(start: 6, end: 4, duration: 10) == nil,
       "inverted range → nil")
expect(Geometry.clampedTrim(start: 5.0, end: 5.05, duration: 10) == nil,
       "sub-0.1s range → nil")
expect(Geometry.clampedTrim(start: 1, end: 9, duration: 0) == nil,
       "zero duration → nil")

// clampedTrim: clamping and normal cases
if let trim = Geometry.clampedTrim(start: 1.5, end: 4.8, duration: 10) {
    expect(trim.start == 1.5 && trim.end == 4.8,
           "normal range passes through (got \(trim))")
} else { expect(false, "expected a trim for 1.5–4.8 of 10s") }
if let trim = Geometry.clampedTrim(start: -3, end: 4, duration: 10) {
    expect(trim.start == 0 && trim.end == 4,
           "negative start clamps to 0 (got \(trim))")
} else { expect(false, "expected a trim for -3–4 of 10s") }
if let trim = Geometry.clampedTrim(start: 2, end: 15, duration: 10) {
    expect(trim.start == 2 && trim.end == 10,
           "end past duration clamps (got \(trim))")
} else { expect(false, "expected a trim for 2–15 of 10s") }
if let trim = Geometry.clampedTrim(start: 2, end: nil, duration: 10) {
    expect(trim.start == 2 && trim.end == 10,
           "start-only trim runs to the end (got \(trim))")
} else { expect(false, "expected a trim for start-only 2s of 10s") }

// speedPercent: log2 slider maps to ticked percents
expectEqual(Geometry.speedPercent(sliderValue: 0), 100, "centre → 100%")
expectEqual(Geometry.speedPercent(sliderValue: 2), 400, "max → 400%")
expectEqual(Geometry.speedPercent(sliderValue: -2), 25, "min → 25%")
expectEqual(Geometry.speedPercent(sliderValue: 1), 200, "+1 → 200%")
expectEqual(Geometry.speedPercent(sliderValue: -1), 50, "-1 → 50%")
expectEqual(Geometry.speedPercent(sliderValue: 0.5), 140, "half-step rounds to nearest 5%")
expectEqual(Geometry.speedPercent(sliderValue: 3), 400, "past max clamps to 400%")
expectEqual(Geometry.speedPercent(sliderValue: -3), 25, "past min clamps to 25%")

// speedFactor: no-op near 100%, else clamped multiplier
expect(Geometry.speedFactor(percent: 100) == nil, "100% → nil (no filter)")
expect(Geometry.speedFactor(percent: 99) == nil, "99% within deadband → nil")
expect(Geometry.speedFactor(percent: 102) == nil, "102% within deadband → nil")
expect(Geometry.speedFactor(percent: 0) == nil, "0% → nil")
expect(Geometry.speedFactor(percent: -50) == nil, "negative → nil")
expectEqual(Geometry.speedFactor(percent: 150), 1.5, "150% → 1.5x")
expectEqual(Geometry.speedFactor(percent: 25), 0.25, "25% → 0.25x")
expectEqual(Geometry.speedFactor(percent: 1000), 4.0, "over-range clamps to 4.0x")

// aspectFitFrame: letterbox math for the crop overlay
let fit16by9 = Geometry.aspectFitFrame(content: PixelSize(width: 320, height: 180),
                                       containerWidth: 320, containerHeight: 240)
expect(fit16by9.x == 0 && fit16by9.width == 320,
       "16:9 in 320×240 fills width (got \(fit16by9))")
expect(fit16by9.y == 30 && fit16by9.height == 180,
       "16:9 letterboxes to y=30 h=180 (got \(fit16by9))")
let fitExact = Geometry.aspectFitFrame(content: PixelSize(width: 100, height: 100),
                                       containerWidth: 200, containerHeight: 200)
expect(fitExact.x == 0 && fitExact.y == 0 && fitExact.width == 200 && fitExact.height == 200,
       "same aspect fills the container (got \(fitExact))")

// normalizedCrop: order, clamp, and Y-flip (view is bottom-left)
let fullFit = (x: 0.0, y: 0.0, width: 320.0, height: 240.0)
if let n = Geometry.normalizedCrop(from: (0, 0), to: (320, 240), fit: fullFit) {
    expect(abs(n.x) < 1e-9 && abs(n.y) < 1e-9
           && abs(n.width - 1) < 1e-9 && abs(n.height - 1) < 1e-9,
           "full drag → whole frame (got \(n))")
} else { expect(false, "full-frame drag should normalize") }
if let n = Geometry.normalizedCrop(from: (320, 240), to: (0, 0), fit: fullFit) {
    expect(abs(n.width - 1) < 1e-9 && abs(n.height - 1) < 1e-9,
           "reversed corners normalize the same (got \(n))")
} else { expect(false, "reversed drag should normalize") }
if let n = Geometry.normalizedCrop(from: (0, 0), to: (320, 120), fit: fullFit) {
    expect(abs(n.y - 0.5) < 1e-9 && abs(n.height - 0.5) < 1e-9,
           "bottom-half view drag maps to top-left y=0.5,h=0.5 (got \(n))")
} else { expect(false, "bottom-half drag should normalize") }
let insetFit = (x: 0.0, y: 30.0, width: 320.0, height: 180.0)
if let n = Geometry.normalizedCrop(from: (-50, -50), to: (400, 300), fit: insetFit) {
    expect(abs(n.x) < 1e-9 && abs(n.y) < 1e-9
           && abs(n.width - 1) < 1e-9 && abs(n.height - 1) < 1e-9,
           "drag beyond frame clamps to full (got \(n))")
} else { expect(false, "over-drag should clamp, not nil") }
expect(Geometry.normalizedCrop(from: (10, 10), to: (12, 12), fit: fullFit) == nil,
       "tiny drag → nil")
expect(Geometry.normalizedCrop(from: (0, 0), to: (320, 20), fit: insetFit) == nil,
       "drag entirely inside a letterbox bar → nil")

// pixelCrop: normalized → source pixels, even dims, clamped, no-op contract
if let px = Geometry.pixelCrop(NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                               in: PixelSize(width: 640, height: 480)) {
    expectEqual(px, CropRect(x: 160, y: 120, width: 320, height: 240),
                "quarter-centered crop → 160,120,320,240")
} else { expect(false, "mid crop should map to pixels") }
expect(Geometry.pixelCrop(NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                          in: PixelSize(width: 640, height: 480)) == nil,
       "full-frame crop → nil (no-op)")
expect(Geometry.pixelCrop(NormalizedRect(x: 0.005, y: 0.005, width: 0.99, height: 0.99),
                          in: PixelSize(width: 640, height: 480)) == nil,
       "within-1% of full → nil")
expect(Geometry.pixelCrop(NormalizedRect(x: 0, y: 0, width: 0.01, height: 0.01),
                          in: PixelSize(width: 640, height: 480)) == nil,
       "sub-16px crop → nil")
if let px = Geometry.pixelCrop(NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                               in: PixelSize(width: 641, height: 481)) {
    expect(px.width % 2 == 0 && px.height % 2 == 0, "crop dims are even (got \(px))")
    expect(px.x + px.width <= 641 && px.y + px.height <= 481,
           "crop stays inside the frame (got \(px))")
} else { expect(false, "half crop of odd-sized frame should map") }

// Random tokens have the expected shape.
let token = Geometry.randomToken()
expect(token.count == 4, "random token is 4 chars (got \(token))")
expect(token.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) },
       "token uses safe charset (got \(token))")

if failures > 0 {
    print("\(failures) geometry test(s) failed")
    exit(1)
}
print("All geometry tests passed")
