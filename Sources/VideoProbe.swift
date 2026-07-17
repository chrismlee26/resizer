import AVFoundation

/// Loads the metadata the options panel shows for a dropped video:
/// display resolution, duration, and file size on disk.

struct VideoInfo {
    let pixelSize: PixelSize    // display size, rotation applied
    let duration: Double        // seconds
    let fileBytes: Int
}

enum VideoProbeError: LocalizedError {
    case noVideoTrack(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack(let name): return "\(name) has no video track"
        }
    }
}

enum VideoProbe {
    static func info(for url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProbeError.noVideoTrack(url.lastPathComponent)
        }
        // Apply the track transform so portrait phone footage reports its
        // display orientation, not the sensor's landscape natural size.
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return VideoInfo(
            pixelSize: PixelSize(width: max(Int(abs(rect.width).rounded()), 1),
                                 height: max(Int(abs(rect.height).rounded()), 1)),
            duration: duration.seconds,
            fileBytes: (attrs[.size] as? Int) ?? 0
        )
    }
}
