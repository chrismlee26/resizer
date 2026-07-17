import Foundation

/// Converts videos to GIF via ffmpeg's two-pass palette pipeline
/// (palettegen + paletteuse) for the best quality-per-byte.

struct GifSettings {
    var width: Int          // output pixel width; height follows aspect
    var fps: Int            // frames per second
    var colors: Int         // palette size, 2...256
    var targetBytes: Int?   // optional max file size; shrinks width to hit it
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

    /// Convert `url` to GIF. With `output` nil, an auto-named file
    /// ("name-<width>w-<token>.gif") is created next to the original.
    /// An explicit `output` (user-chosen via save panel) may be overwritten —
    /// the save panel already asked for confirmation.
    static func convert(_ url: URL, settings: GifSettings, output explicit: URL? = nil,
                        progress: ((String) -> Void)? = nil) throws -> GifResult {
        let ffmpeg = try ffmpegPath()
        let output = explicit ?? Geometry.outputURL(for: url, suffix: "\(settings.width)w", ext: "gif") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard output != url else {
            throw ToolError.commandFailed(tool: "ffmpeg", status: 0,
                                          stderr: "output would overwrite the original file")
        }

        var width = settings.width
        var attempts = 0
        let maxAttempts = settings.targetBytes == nil ? 1 : 5

        while true {
            attempts += 1
            try encode(ffmpeg: ffmpeg, input: url, output: output,
                       width: width, fps: settings.fps, colors: settings.colors)
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

    private static func encode(ffmpeg: String, input: URL, output: URL,
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

    /// Rough output-size prediction for live UI feedback while the user
    /// tweaks settings. A GIF stores every frame as LZW-compressed indexed
    /// pixels (log2(colors) bits each); on bayer-dithered video frames LZW
    /// typically lands near 2:1, hence the 0.5 factor. Expect real results
    /// within about a factor of two either way.
    static func estimatedBytes(settings: GifSettings, source: PixelSize,
                               duration: Double) -> Int {
        let aspect = Double(source.height) / Double(max(source.width, 1))
        let height = (Double(settings.width) * aspect).rounded()
        let frames = max(Double(settings.fps) * duration, 1)
        let bitsPerPixel = log2(Double(max(settings.colors, 2)))
        let lzwCompression = 0.5
        return Int(frames * Double(settings.width) * height
                   * bitsPerPixel / 8 * lzwCompression)
    }

    private static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    static func format(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
