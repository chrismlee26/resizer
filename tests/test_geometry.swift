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
