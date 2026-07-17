import AppKit
import AVFoundation
import AVKit

/// Inline video preview with a two-handle trim slider. Dragging a handle
/// seeks the (muted) player to that handle's frame, playback is confined
/// to the selected range, and the range is reported through
/// `onTrimChanged` — (nil, nil) means "export the full clip".
final class VideoTrimView: NSView {
    /// AVPlayerView has no intrinsic content size, so the preview needs
    /// explicit dimensions or the window's fittingSize collapses it.
    private static let previewWidth: CGFloat = 320
    private static let minPreviewHeight: CGFloat = 80
    private static let maxPreviewHeight: CGFloat = 240
    /// Smallest allowed exported range, in seconds.
    private static let minRange = 0.1
    private static let timescale: CMTimeScale = 600

    var onTrimChanged: ((Double?, Double?) -> Void)?

    private let playerView = AVPlayerView()
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private let rangeSlider = TrimRangeSlider()
    private let startValueLabel = NSTextField(labelWithString: "0.0 s")
    private let endValueLabel = NSTextField(labelWithString: "…")
    private let rangeLabel = NSTextField(labelWithString: "")
    private var previewHeightConstraint: NSLayoutConstraint?
    private var duration: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - API

    func load(url: URL) {
        let player = AVPlayer(url: url)
        player.isMuted = true
        self.player = player
        playerView.player = player

        // When playback hits the trim end (forwardPlaybackEndTime), rewind
        // to the trim start so Play always replays the selection.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.seekPreview(to: self.rangeSlider.startValue)
        }
    }

    /// Called once the async metadata probe finishes.
    func setDuration(_ seconds: Double) {
        duration = max(seconds, 0)
        rangeSlider.maxValue = max(duration, .ulpOfOne)
        rangeSlider.minimumGap = Self.minRange
        rangeSlider.startValue = 0
        rangeSlider.endValue = duration
        rangeSlider.isEnabled = duration > 0
        updateLabels()
    }

    /// Size the preview to the clip's aspect ratio at a fixed width,
    /// with the height clamped so extreme aspect ratios stay compact.
    func setAspectRatio(_ size: PixelSize) {
        let aspect = Double(size.height) / Double(max(size.width, 1))
        let height = min(max(Self.previewWidth * aspect, Self.minPreviewHeight),
                         Self.maxPreviewHeight)
        previewHeightConstraint?.constant = height
    }

    /// Stop playback when the owning window closes.
    func teardown() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        playerView.player = nil
        player = nil
    }

    // MARK: - UI

    private func buildUI() {
        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.widthAnchor.constraint(equalToConstant: Self.previewWidth)
            .isActive = true
        let height = playerView.heightAnchor.constraint(
            equalToConstant: Self.minPreviewHeight)
        height.isActive = true
        previewHeightConstraint = height

        rangeSlider.onChanged = { [weak self] handle in
            self?.rangeChanged(draggedHandle: handle)
        }
        rangeSlider.widthAnchor.constraint(equalToConstant: 216).isActive = true

        for label in [startValueLabel, endValueLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        endValueLabel.alignment = .right
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.isHidden = true

        let sliderRow = NSStackView(views: [startValueLabel, rangeSlider, endValueLabel])
        sliderRow.orientation = .horizontal
        sliderRow.spacing = 8

        let stack = NSStackView(views: [playerView, sliderRow, rangeLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Trim handling

    private func rangeChanged(draggedHandle: TrimRangeSlider.Handle) {
        guard duration > 0 else { return }
        let movedTo = draggedHandle == .start
            ? rangeSlider.startValue : rangeSlider.endValue
        seekPreview(to: movedTo)
        updateLabels()

        let trimmed = Geometry.clampedTrim(start: rangeSlider.startValue,
                                           end: rangeSlider.endValue,
                                           duration: duration)
        applyPlaybackBounds(trimmed)
        onTrimChanged?(trimmed?.start, trimmed?.end)
    }

    /// Confine the preview's playback to the selected range, so pressing
    /// Play shows exactly what will be exported. A nil trim (full range)
    /// removes the bounds.
    private func applyPlaybackBounds(_ trim: (start: Double, end: Double)?) {
        guard let item = player?.currentItem else { return }
        if let trim {
            item.reversePlaybackEndTime = time(trim.start)
            item.forwardPlaybackEndTime = time(trim.end)
        } else {
            item.reversePlaybackEndTime = .invalid
            item.forwardPlaybackEndTime = .invalid
        }
    }

    /// Show the exact frame under the dragged handle.
    private func seekPreview(to seconds: Double) {
        guard let player else { return }
        player.pause()
        player.seek(to: time(seconds), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: Self.timescale)
    }

    private func updateLabels() {
        let start = rangeSlider.startValue
        let end = rangeSlider.endValue
        startValueLabel.stringValue = String(format: "%.1f s", start)
        endValueLabel.stringValue = String(format: "%.1f s", end)

        let isFullRange = Geometry.clampedTrim(start: start, end: end,
                                               duration: duration) == nil
        rangeLabel.isHidden = isFullRange
        if !isFullRange {
            rangeLabel.stringValue = String(
                format: "Exporting %.1f–%.1f s (%.1f s)", start, end, end - start)
        }
    }
}
