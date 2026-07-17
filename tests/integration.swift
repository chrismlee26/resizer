import Foundation

// End-to-end check of the sips and ffmpeg pipelines against generated
// fixtures. Expects a writable working directory as argv[1] containing
// test.png (400x300) and test.mov — created by tests/run_tests.sh.

let workDir = URL(fileURLWithPath: CommandLine.arguments[1])
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
    else { print("ok: \(message)") }
}

// Image: read size
let png = workDir.appendingPathComponent("test.png")
let size = try ImageProcessor.pixelSize(of: png)
expect(size == PixelSize(width: 400, height: 300), "pixelSize reads 400x300, got \(size)")

// Image: 50% resize
let half = try ImageProcessor.resize(png, mode: .percent(50))
expect(FileManager.default.fileExists(atPath: half.output.path), "50% output exists")
let halfSize = try ImageProcessor.pixelSize(of: half.output)
expect(halfSize == PixelSize(width: 200, height: 150), "50% output is 200x150, got \(halfSize)")

// Image: original untouched
let originalSize = try ImageProcessor.pixelSize(of: png)
expect(originalSize == PixelSize(width: 400, height: 300), "original file untouched")

// Image: fit-within resize + collision naming
let fit = try ImageProcessor.resize(png, mode: .fit(PixelSize(width: 100, height: 100)))
let fitSize = try ImageProcessor.pixelSize(of: fit.output)
expect(fitSize == PixelSize(width: 100, height: 75), "fit 100x100 gives 100x75, got \(fitSize)")

// GIF: basic conversion
let mov = workDir.appendingPathComponent("test.mov")
let gif = try GifProcessor.convert(
    mov, settings: GifSettings(width: 200, fps: 10, colors: 64, targetBytes: nil))
expect(FileManager.default.fileExists(atPath: gif.output.path), "gif output exists")
expect(gif.bytes > 0, "gif is non-empty (\(gif.bytes) bytes)")
let gifSize = try ImageProcessor.pixelSize(of: gif.output)
expect(gifSize.width == 200, "gif width is 200, got \(gifSize.width)")

// GIF: target size forces shrink
let big = try GifProcessor.convert(
    mov, settings: GifSettings(width: 320, fps: 15, colors: 256, targetBytes: nil))
let target = max(big.bytes / 2, 20_000)
let squeezed = try GifProcessor.convert(
    mov, settings: GifSettings(width: 320, fps: 15, colors: 256, targetBytes: target))
expect(squeezed.attempts > 1, "target size triggered a retry (\(squeezed.attempts) attempts)")
expect(squeezed.bytes <= target || squeezed.width == 40,
       "squeezed gif \(squeezed.bytes)B vs target \(target)B (width \(squeezed.width))")

if failures > 0 { print("\(failures) integration test(s) failed"); exit(1) }
print("All integration tests passed")
