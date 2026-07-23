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

// GIF: gifsicle lossy pass shrinks output (skipped when not installed)
if ToolRunner.find("gifsicle") != nil {
    let balanced = try GifProcessor.convert(
        mov, settings: GifSettings(width: 320, fps: 15, colors: 256,
                                   targetBytes: nil, lossy: 30))
    let strong = try GifProcessor.convert(
        mov, settings: GifSettings(width: 320, fps: 15, colors: 256,
                                   targetBytes: nil, lossy: 80))
    expect(balanced.bytes > 0, "balanced gif is non-empty (\(balanced.bytes) bytes)")
    expect(balanced.bytes < big.bytes,
           "lossy=30 beats uncompressed (\(balanced.bytes)B < \(big.bytes)B)")
    expect(strong.bytes < balanced.bytes,
           "lossy=80 beats lossy=30 (\(strong.bytes)B < \(balanced.bytes)B)")
    let lossySize = try ImageProcessor.pixelSize(of: balanced.output)
    expect(lossySize.width == 320, "lossy gif keeps width 320, got \(lossySize.width)")
} else {
    print("skip: gifsicle not installed, lossy tests skipped")
}

// GIF: lossy estimate scales down with level
let plainEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil),
    source: PixelSize(width: 320, height: 240), duration: 2)
let balancedEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil, lossy: 30),
    source: PixelSize(width: 320, height: 240), duration: 2)
let strongEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil, lossy: 80),
    source: PixelSize(width: 320, height: 240), duration: 2)
expect(balancedEstimate < plainEstimate && strongEstimate < balancedEstimate,
       "estimates scale with lossy level (\(plainEstimate) → \(balancedEstimate) → \(strongEstimate))")

// WebP: basic conversion
let webp = try GifProcessor.convert(
    mov, settings: GifSettings(width: 200, fps: 10, colors: 128,
                               targetBytes: nil, format: .webp))
expect(webp.output.pathExtension == "webp", "webp output has .webp extension")
expect(FileManager.default.fileExists(atPath: webp.output.path), "webp output exists")
expect(webp.bytes > 0, "webp is non-empty (\(webp.bytes) bytes)")
let webpSize = try ImageProcessor.pixelSize(of: webp.output)
expect(webpSize.width == 200, "webp width is 200, got \(webpSize.width)")

// WebP: smaller than the equivalent GIF
let webpBig = try GifProcessor.convert(
    mov, settings: GifSettings(width: 320, fps: 15, colors: 256,
                               targetBytes: nil, format: .webp))
expect(webpBig.bytes < big.bytes,
       "webp beats gif at same settings (\(webpBig.bytes)B < \(big.bytes)B)")

// WebP: estimator is format-aware and far below the GIF estimate
let webpEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 256,
                          targetBytes: nil, format: .webp),
    source: PixelSize(width: 320, height: 240), duration: 2)
let gifEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 256, targetBytes: nil),
    source: PixelSize(width: 320, height: 240), duration: 2)
expect(webpEstimate > 0 && webpEstimate < gifEstimate / 2,
       "webp estimate well under gif (\(webpEstimate) vs \(gifEstimate))")

// Trim: ffmpeg argument construction
let fullTrim = GifProcessor.trimArguments(start: 1.5, end: 4.75)
expect(fullTrim.input == ["-ss", "1.500"] && fullTrim.output == ["-t", "3.250"],
       "trim args for 1.5–4.75 (got \(fullTrim))")
let noTrim = GifProcessor.trimArguments(start: nil, end: nil)
expect(noTrim.input.isEmpty && noTrim.output.isEmpty, "no trim → no args")
let startOnly = GifProcessor.trimArguments(start: 2, end: nil)
expect(startOnly.input == ["-ss", "2.000"] && startOnly.output.isEmpty,
       "start-only trim emits only -ss (got \(startOnly))")
let endOnly = GifProcessor.trimArguments(start: nil, end: 3)
expect(endOnly.input.isEmpty && endOnly.output == ["-t", "3.000"],
       "end-only trim emits only -t (got \(endOnly))")

// Trim: estimator scales with the exported duration
let trimmedEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil,
                          trimStart: 0, trimEnd: 1),
    source: PixelSize(width: 320, height: 240), duration: 2)
let untrimmedEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil),
    source: PixelSize(width: 320, height: 240), duration: 2)
expect(trimmedEstimate * 2 == untrimmedEstimate,
       "half-duration trim halves estimate (\(untrimmedEstimate) → \(trimmedEstimate))")

// Trim: end-to-end conversion of a sub-range
let trimmedGif = try GifProcessor.convert(
    mov, settings: GifSettings(width: 320, fps: 15, colors: 256, targetBytes: nil,
                               trimStart: 0.5, trimEnd: 1.5))
expect(FileManager.default.fileExists(atPath: trimmedGif.output.path),
       "trimmed gif output exists")
expect(trimmedGif.bytes > 0, "trimmed gif is non-empty (\(trimmedGif.bytes) bytes)")
expect(trimmedGif.bytes < big.bytes,
       "trimmed gif smaller than full clip (\(trimmedGif.bytes)B < \(big.bytes)B)")

// Trim: WebP path honors the trim too
let trimmedWebp = try GifProcessor.convert(
    mov, settings: GifSettings(width: 320, fps: 15, colors: 256, targetBytes: nil,
                               format: .webp, trimStart: 0.5, trimEnd: 1.5))
expect(trimmedWebp.bytes > 0 && trimmedWebp.bytes < webpBig.bytes,
       "trimmed webp smaller than full clip (\(trimmedWebp.bytes)B < \(webpBig.bytes)B)")

// Speed: filter construction — no speed leaves today's exact string
let normalFilter = GifProcessor.videoFilters(width: 320, fps: 15)
expect(normalFilter == "fps=15,scale=320:-2:flags=lanczos",
       "no speed → unchanged filter (got \(normalFilter))")
let fastFilter = GifProcessor.videoFilters(width: 320, fps: 15, speed: 2)
expect(fastFilter == "setpts=(PTS-STARTPTS)/2,fps=15,scale=320:-2:flags=lanczos",
       "2x speed prepends setpts before fps (got \(fastFilter))")
let slowFilter = GifProcessor.videoFilters(width: 320, fps: 15, speed: 0.5)
expect(slowFilter == "setpts=(PTS-STARTPTS)/0.5,fps=15,scale=320:-2:flags=lanczos",
       "0.5x speed prepends setpts (got \(slowFilter))")

// Speed: -t scales by 1/speed so the exported window stays correct
let fastTrim = GifProcessor.trimArguments(start: 1.5, end: 4.75, speed: 2)
expect(fastTrim.output == ["-t", "1.625"], "2x halves -t (got \(fastTrim.output))")
let slowTrim = GifProcessor.trimArguments(start: 1.5, end: 4.75, speed: 0.5)
expect(slowTrim.output == ["-t", "6.500"], "0.5x doubles -t (got \(slowTrim.output))")

// Speed: estimator scales inversely with playback speed
let normalSpeedEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil),
    source: PixelSize(width: 320, height: 240), duration: 2)
let fastEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil, speed: 2),
    source: PixelSize(width: 320, height: 240), duration: 2)
expect(fastEstimate * 2 == normalSpeedEstimate,
       "2x speed halves estimate (\(normalSpeedEstimate) → \(fastEstimate))")

// Speed: end-to-end — 2x smaller, 0.5x larger than the full-speed clip
let fastGif = try GifProcessor.convert(
    mov, settings: GifSettings(width: 320, fps: 15, colors: 256, targetBytes: nil, speed: 2))
expect(fastGif.bytes > 0 && fastGif.bytes < big.bytes,
       "2x speed gif smaller than normal (\(fastGif.bytes)B < \(big.bytes)B)")
let slowGif = try GifProcessor.convert(
    mov, settings: GifSettings(width: 320, fps: 15, colors: 256, targetBytes: nil, speed: 0.5))
expect(slowGif.bytes > big.bytes,
       "0.5x speed gif larger than normal (\(slowGif.bytes)B > \(big.bytes)B)")

// Crop: filter uses crop and drops scale entirely (exact-size, native res)
let cropFilter = GifProcessor.videoFilters(
    width: 320, fps: 15, crop: CropRect(x: 80, y: 60, width: 160, height: 120))
expect(cropFilter == "fps=15,crop=160:120:80:60",
       "crop replaces scale (got \(cropFilter))")
let cropSpeedFilter = GifProcessor.videoFilters(
    width: 320, fps: 15, speed: 2, crop: CropRect(x: 0, y: 0, width: 200, height: 100))
expect(cropSpeedFilter == "setpts=(PTS-STARTPTS)/2,fps=15,crop=200:100:0:0",
       "crop and speed compose (got \(cropSpeedFilter))")

// Crop: estimator uses the crop's own dimensions as the output size
let cropEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil,
                          crop: CropRect(x: 0, y: 0, width: 160, height: 120)),
    source: PixelSize(width: 320, height: 240), duration: 2)
let fullAreaEstimate = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil),
    source: PixelSize(width: 320, height: 240), duration: 2)
expect(cropEstimate * 4 == fullAreaEstimate,
       "quarter-area crop quarters the estimate (\(fullAreaEstimate) → \(cropEstimate))")

// Crop: end-to-end — output is exactly the crop size, ignoring Width
let croppedGif = try GifProcessor.convert(
    mov, settings: GifSettings(width: 999, fps: 15, colors: 256, targetBytes: nil,
                               crop: CropRect(x: 80, y: 60, width: 160, height: 120)))
expect(croppedGif.attempts == 1, "crop forces a single attempt (\(croppedGif.attempts))")
let croppedSize = try ImageProcessor.pixelSize(of: croppedGif.output)
expect(croppedSize == PixelSize(width: 160, height: 120),
       "cropped gif is exactly 160×120 despite Width 999, got \(croppedSize)")

// Crop: WebP path honors the crop too, at native size
let croppedWebp = try GifProcessor.convert(
    mov, settings: GifSettings(width: 999, fps: 15, colors: 256, targetBytes: nil,
                               format: .webp,
                               crop: CropRect(x: 80, y: 60, width: 160, height: 120)))
let croppedWebpSize = try ImageProcessor.pixelSize(of: croppedWebp.output)
expect(croppedWebpSize == PixelSize(width: 160, height: 120),
       "cropped webp is exactly 160×120, got \(croppedWebpSize)")

// GIF: size estimator sanity
let base = GifSettings(width: 320, fps: 15, colors: 128, targetBytes: nil)
let source = PixelSize(width: 320, height: 240)
let estimate = GifProcessor.estimatedBytes(settings: base, source: source, duration: 2)
expect(estimate > 0, "estimate is positive (\(estimate) bytes)")

let doubleFps = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 30, colors: 128, targetBytes: nil),
    source: source, duration: 2)
expect(doubleFps == estimate * 2, "double fps doubles estimate (\(estimate) → \(doubleFps))")

let fewerColors = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 16, targetBytes: nil),
    source: source, duration: 2)
expect(fewerColors < estimate, "fewer colors shrinks estimate (\(estimate) → \(fewerColors))")

let halfWidth = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 160, fps: 15, colors: 128, targetBytes: nil),
    source: source, duration: 2)
expect(abs(halfWidth * 4 - estimate) <= 4,
       "half width quarters estimate (\(estimate) → \(halfWidth))")

// Synthetic testsrc frames are a best case for LZW, so the real file lands
// well under the estimate — just require the estimate to be an upper bound
// of the right order of magnitude.
let estimated = GifProcessor.estimatedBytes(
    settings: GifSettings(width: 320, fps: 15, colors: 256, targetBytes: nil),
    source: PixelSize(width: 320, height: 240), duration: 2)
expect(big.bytes <= estimated && estimated < big.bytes * 100,
       "estimate \(estimated)B brackets actual \(big.bytes)B")

if failures > 0 { print("\(failures) integration test(s) failed"); exit(1) }
print("All integration tests passed")
