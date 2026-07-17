import Foundation

/// Converts videos to GIF via ffmpeg's two-pass palette pipeline
/// (palettegen + paletteuse) for the best quality-per-byte.

enum VideoOutputFormat: String {
    case gif
    case webp

    var fileExtension: String { rawValue }
    var displayName: String { rawValue == "gif" ? "GIF" : "WebP" }
}

struct GifSettings {
    var width: Int          // output pixel width; height follows aspect
    var fps: Int            // frames per second
    var colors: Int         // palette size, 2...256 (GIF only)
    var targetBytes: Int?   // optional max file size; shrinks width to hit it
    var lossy: Int? = nil   // gifsicle --lossy level (nil = skip gifsicle pass)
    var format: VideoOutputFormat = .gif

    /// The Compression dropdown doubles as the WebP quality knob:
    /// None → q90, Balanced (30) → q75, Strong (80) → q50.
    var webpQuality: Int {
        guard let lossy else { return 90 }
        return lossy >= 80 ? 50 : 75
    }
}

struct GifResult {
    let source: URL
    let output: URL
    let width: Int
    let bytes: Int
    let attempts: Int
}

enum GifProcessor {
    static func ffmpegPath() throws -> String {
        guard let path = ToolRunner.find("ffmpeg") else {
            throw ToolError.toolNotFound("ffmpeg")
        }
        return path
    }

    /// Convert `url` to GIF or animated WebP. With `output` nil, an
    /// auto-named file ("name-<width>w-<token>.<ext>") is created next to
    /// the original. An explicit `output` (user-chosen via save panel) may
    /// be overwritten — the save panel already asked for confirmation.
    static func convert(_ url: URL, settings: GifSettings, output explicit: URL? = nil,
                        progress: ((String) -> Void)? = nil) throws -> GifResult {
        let ffmpeg = try ffmpegPath()
        let output = explicit ?? Geometry.outputURL(for: url, suffix: "\(settings.width)w",
                                                    ext: settings.format.fileExtension) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard output != url else {
            throw ToolError.commandFailed(tool: "ffmpeg", status: 0,
                                          stderr: "output would overwrite the original file")
        }

        var width = settings.width
        var attempts = 0
        let maxAttempts = settings.targetBytes == nil ? 1 : 5

        // Resolve gifsicle up front so a missing tool fails before the
        // (slow) ffmpeg encode, not after it. WebP never needs it.
        let gifsicle: String? = settings.format == .gif
            ? try settings.lossy.map { _ in
                guard let path = ToolRunner.find("gifsicle") else {
                    throw ToolError.toolNotFound("gifsicle")
                }
                return path
            }
            : nil

        while true {
            attempts += 1
            switch settings.format {
            case .gif:
                try encodeGif(ffmpeg: ffmpeg, input: url, output: output,
                              width: width, fps: settings.fps, colors: settings.colors)
                if let gifsicle, let lossy = settings.lossy {
                    // -b rewrites in place; -O3 adds frame-diff + transparency
                    // optimization on top of the lossy LZW recompression.
                    try ToolRunner.run(gifsicle, ["-b", "-O3", "--lossy=\(lossy)", output.path])
                }
            case .webp:
                try encodeWebp(ffmpeg: ffmpeg, input: url, output: output,
                               width: width, fps: settings.fps,
                               quality: settings.webpQuality)
            }
            let bytes = fileSize(output)

            guard let target = settings.targetBytes, bytes > target else {
                return GifResult(source: url, output: output, width: width,
                                 bytes: bytes, attempts: attempts)
            }
            guard attempts < maxAttempts,
                  let nextWidth = Geometry.nextGifWidth(currentWidth: width,
                                                        actualBytes: bytes,
                                                        targetBytes: target) else {
                // Out of room to shrink — return what we have, caller reports size.
                return GifResult(source: url, output: output, width: width,
                                 bytes: bytes, attempts: attempts)
            }
            progress?("\(format(bytes: bytes)) > target, retrying at \(nextWidth)px…")
            width = nextWidth
        }
    }

    private static func encodeGif(ffmpeg: String, input: URL, output: URL,
                                  width: Int, fps: Int, colors: Int) throws {
        // stats_mode=diff weights the palette toward pixels that change between
        // frames; diff_mode=rectangle re-encodes only the changing region of
        // each frame. Both shrink output at no quality cost for the static
        // parts (big win for screen recordings, modest for full-motion video).
        let filter = "fps=\(fps),scale=\(width):-2:flags=lanczos,"
            + "split[s0][s1];[s0]palettegen=max_colors=\(colors):stats_mode=diff[p];"
            + "[s1][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
        try ToolRunner.run(ffmpeg, [
            "-y", "-i", input.path,
            "-vf", filter,
            "-loop", "0",
            output.path,
        ])
    }

    private static func encodeWebp(ffmpeg: String, input: URL, output: URL,
                                   width: Int, fps: Int, quality: Int) throws {
        try ToolRunner.run(ffmpeg, [
            "-y", "-i", input.path,
            "-vf", "fps=\(fps),scale=\(width):-2:flags=lanczos",
            "-c:v", "libwebp", "-q:v", "\(quality)",
            "-loop", "0", "-an",
            output.path,
        ])
    }

    /// Rough output-size prediction for live UI feedback while the user
    /// tweaks settings. Expect real results within about a factor of two
    /// either way.
    ///
    /// GIF: every frame is LZW-compressed indexed pixels (log2(colors) bits
    /// each); on bayer-dithered video frames LZW typically lands near 2:1,
    /// hence the 0.5 factor.
    /// WebP: bytes/pixel/frame by quality, measured on sample encodes
    /// (q90 ≈ 0.08, q75 ≈ 0.05, q50 ≈ 0.035).
    static func estimatedBytes(settings: GifSettings, source: PixelSize,
                               duration: Double) -> Int {
        let aspect = Double(source.height) / Double(max(source.width, 1))
        let height = (Double(settings.width) * aspect).rounded()
        let frames = max(Double(settings.fps) * duration, 1)
        let pixelFrames = frames * Double(settings.width) * height

        switch settings.format {
        case .gif:
            let bitsPerPixel = log2(Double(max(settings.colors, 2)))
            let lzwCompression = 0.5
            // Typical reductions from the gifsicle pass: the UI's
            // "Balanced" (30) lands near -20%, "Strong" (80) near -35%.
            let lossyFactor = settings.lossy
                .map { $0 >= 80 ? 0.65 : ($0 >= 30 ? 0.8 : 0.9) } ?? 1.0
            return Int(pixelFrames * bitsPerPixel / 8 * lzwCompression * lossyFactor)
        case .webp:
            let bytesPerPixelFrame: Double
            switch settings.webpQuality {
            case ..<75: bytesPerPixelFrame = 0.035
            case ..<90: bytesPerPixelFrame = 0.05
            default: bytesPerPixelFrame = 0.08
            }
            return Int(pixelFrames * bytesPerPixelFrame)
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    static func format(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
