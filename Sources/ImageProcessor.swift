import Foundation

/// Resizes images by shelling out to /usr/bin/sips.
/// The original file is never touched: we copy to the output path first,
/// then resample the copy in place.

struct ImageResult {
    let source: URL
    let output: URL
    let size: PixelSize
    let bytes: Int
}

enum ImageProcessor {
    static let sipsPath = "/usr/bin/sips"

    static func pixelSize(of url: URL) throws -> PixelSize {
        let result = try ToolRunner.run(sipsPath, [
            "-g", "pixelWidth", "-g", "pixelHeight", url.path,
        ])
        var width = 0, height = 0
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            if parts[0] == "pixelWidth" { width = value }
            if parts[0] == "pixelHeight" { height = value }
        }
        guard width > 0, height > 0 else {
            throw ToolError.commandFailed(tool: "sips", status: 0,
                                          stderr: "could not read dimensions of \(url.lastPathComponent)")
        }
        return PixelSize(width: width, height: height)
    }

    /// Resize `url`. With `output` nil, an auto-named copy
    /// ("name-<width>w-<token>.ext") is created next to the original.
    /// An explicit `output` (user-chosen via save panel) is replaced if it
    /// exists — the save panel already asked for confirmation.
    static func resize(_ url: URL, mode: ResizeMode, output explicit: URL? = nil) throws -> ImageResult {
        let sourceSize = try pixelSize(of: url)
        let target = Geometry.targetSize(source: sourceSize, mode: mode)

        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let output = explicit ?? Geometry.outputURL(for: url, suffix: "\(target.width)w", ext: ext) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard output != url else {
            throw ToolError.commandFailed(tool: "sips", status: 0,
                                          stderr: "output would overwrite the original file")
        }

        if explicit != nil, FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.copyItem(at: url, to: output)
        do {
            try ToolRunner.run(sipsPath, [
                "--resampleHeightWidth", String(target.height), String(target.width),
                output.path,
            ])
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: output.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        return ImageResult(source: url, output: output, size: target, bytes: bytes)
    }
}
