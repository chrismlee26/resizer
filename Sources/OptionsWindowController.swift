import AppKit
import UniformTypeIdentifiers

/// The panel that appears after files are dropped. Shows an image section,
/// a GIF section, or both, depending on what was dropped. Runs conversions
/// on a background queue and reports results inline.

final class OptionsWindowController: NSWindowController {
    private let images: [URL]
    private let videos: [URL]

    // Image controls
    private let imageModePopup = NSPopUpButton()
    private let percentField = NSTextField(string: "50")
    private let widthField = NSTextField(string: "1280")
    private let heightField = NSTextField(string: "720")
    private let percentLabel = NSTextField(labelWithString: "%")
    private let percentResultLabel = NSTextField(labelWithString: "")
    private let originalDimsLabel = NSTextField(labelWithString: "Original: …")
    private let timesLabel = NSTextField(labelWithString: "×")
    private let pxLabel = NSTextField(labelWithString: "px")
    private let scaleSlider = NSSlider(value: 100, minValue: 1, maxValue: 100,
                                       target: nil, action: nil)
    private let scaleValueLabel = NSTextField(labelWithString: "100%")
    private var scaleRow: NSStackView?

    /// Resolution of the first dropped image; drives the exact-mode aspect
    /// lock and slider. Loaded asynchronously right after the window opens.
    private var sourcePixelSize: PixelSize?
    private var isProgrammaticFieldUpdate = false

    // GIF controls
    /// FPS presets for video → GIF, highest first. 15 balances smoothness
    /// against file size for most clips; 5 is the floor — anything lower
    /// reads as a slideshow rather than motion.
    private static let gifFpsOptions = [30, 24, 20, 15, 12, 10, 8, 5]
    private static let gifFpsRecommended = 15

    /// Compression presets map to gifsicle --lossy levels; nil skips the
    /// gifsicle pass entirely so it stays usable without the tool installed.
    private static let gifCompressionOptions: [(title: String, lossy: Int?)] = [
        ("None", nil), ("Balanced", 80), ("Strong", 140),
    ]

    private let gifWidthField = NSTextField(string: "640")
    private let gifFpsPopup = NSPopUpButton()
    private let gifColorsPopup = NSPopUpButton()
    private let gifCompressionPopup = NSPopUpButton()
    private let gifTargetField = NSTextField(string: "")
    private let gifOriginalLabel = NSTextField(labelWithString: "Original: …")
    private let gifEstimateLabel = NSTextField(labelWithString: "")

    /// Metadata of the first dropped video; drives the original-size line
    /// and the live GIF size estimate. Loaded async after the window opens.
    private var videoInfo: VideoInfo?

    private let outputModePopup = NSPopUpButton()
    private let convertButton = NSButton(title: "Convert", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let revealCheckbox = NSButton(checkboxWithTitle: "Reveal in Finder when done",
                                          target: nil, action: nil)

    /// Keeps controllers alive while their window is open.
    private static var active: [OptionsWindowController] = []

    static func present(urls: [URL]) {
        let images = urls.filter { FileClassifier.kind(of: $0) == .image }
        let videos = urls.filter { FileClassifier.kind(of: $0) == .video }
        guard !images.isEmpty || !videos.isEmpty else { return }
        let controller = OptionsWindowController(images: images, videos: videos)
        active.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(images: [URL], videos: [URL]) {
        self.images = images
        self.videos = videos
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Resizer"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - UI construction

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        stack.addArrangedSubview(fileSummaryLabel())
        if !images.isEmpty { stack.addArrangedSubview(imageSection()) }
        if !videos.isEmpty { stack.addArrangedSubview(gifSection()) }

        outputModePopup.addItems(withTitles: ["Auto-named copy", "Ask for name…"])
        let outputRow = NSStackView(views: [makeLabel("Output:"), outputModePopup])
        outputRow.orientation = .horizontal
        outputRow.spacing = 6
        stack.addArrangedSubview(outputRow)

        revealCheckbox.state = .on
        stack.addArrangedSubview(revealCheckbox)

        convertButton.target = self
        convertButton.action = #selector(convertPressed)
        convertButton.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor

        let bottomRow = NSStackView(views: [convertButton, spinner, statusLabel])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        stack.addArrangedSubview(bottomRow)
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        window?.contentView = stack
        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(stack.fittingSize)
    }

    private func fileSummaryLabel() -> NSTextField {
        var parts: [String] = []
        if !images.isEmpty {
            parts.append(images.count == 1
                ? images[0].lastPathComponent
                : "\(images.count) images")
        }
        if !videos.isEmpty {
            parts.append(videos.count == 1
                ? videos[0].lastPathComponent
                : "\(videos.count) videos")
        }
        let label = NSTextField(labelWithString: parts.joined(separator: "  +  "))
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func imageSection() -> NSView {
        imageModePopup.addItems(withTitles: [
            "Scale by percent", "Fit within box", "Exact dimensions",
        ])
        imageModePopup.target = self
        imageModePopup.action = #selector(imageModeChanged)

        for field in [percentField, widthField, heightField] {
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }

        widthField.delegate = self
        heightField.delegate = self
        percentField.delegate = self

        originalDimsLabel.textColor = .secondaryLabelColor
        originalDimsLabel.font = .systemFont(ofSize: 12)
        percentResultLabel.textColor = .secondaryLabelColor
        percentResultLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let row = NSStackView(views: [
            imageModePopup,
            percentField, percentLabel, percentResultLabel,
            widthField, timesLabel, heightField, pxLabel,
        ])
        row.orientation = .horizontal
        row.spacing = 6

        scaleSlider.target = self
        scaleSlider.action = #selector(scaleSliderChanged)
        scaleSlider.isContinuous = true
        scaleSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        scaleValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        scaleValueLabel.textColor = .secondaryLabelColor
        scaleValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let slider = NSStackView(views: [scaleSlider, scaleValueLabel])
        slider.orientation = .horizontal
        slider.spacing = 8
        scaleRow = slider

        let rows = NSStackView(views: [originalDimsLabel, row, slider])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8

        imageModeChanged()
        loadSourcePixelSize()
        return section("Resize Images", content: rows)
    }

    /// Read the first image's resolution off the main thread, then prefill
    /// the dimension fields with it (unless the user already typed).
    private func loadSourcePixelSize() {
        guard let first = images.first else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let size = try? ImageProcessor.pixelSize(of: first) else { return }
            DispatchQueue.main.async { self?.sourcePixelSizeLoaded(size) }
        }
    }

    private func sourcePixelSizeLoaded(_ size: PixelSize) {
        sourcePixelSize = size
        var dims = "Original: \(size.width) × \(size.height) px"
        if images.count > 1 { dims += "  (first of \(images.count) images)" }
        originalDimsLabel.stringValue = dims
        isProgrammaticFieldUpdate = true
        widthField.stringValue = String(size.width)
        heightField.stringValue = String(size.height)
        isProgrammaticFieldUpdate = false
        scaleSlider.doubleValue = 100
        scaleValueLabel.stringValue = "100%"
        updatePercentResult()
        refreshWindowSize()
    }

    /// Live "→ W × H px" readout for percent mode, from the first image.
    private func updatePercentResult() {
        guard let source = sourcePixelSize,
              let pct = Double(percentField.stringValue), pct > 0 else {
            percentResultLabel.stringValue = ""
            return
        }
        let target = Geometry.targetSize(source: source, mode: .percent(pct))
        percentResultLabel.stringValue = "→ \(target.width) × \(target.height) px"
    }

    @objc private func scaleSliderChanged() {
        guard let source = sourcePixelSize else { return }
        let pct = scaleSlider.doubleValue
        let target = Geometry.targetSize(source: source, mode: .percent(pct))
        isProgrammaticFieldUpdate = true
        widthField.stringValue = String(target.width)
        heightField.stringValue = String(target.height)
        isProgrammaticFieldUpdate = false
        scaleValueLabel.stringValue = "\(Int(pct.rounded()))%"
    }

    private func gifSection() -> NSView {
        gifColorsPopup.addItems(withTitles: ["256", "128", "64", "32", "16"])
        gifColorsPopup.selectItem(at: 1)

        gifFpsPopup.addItems(withTitles: Self.gifFpsOptions.map {
            $0 == Self.gifFpsRecommended ? "\($0) (Recommended)" : "\($0)"
        })
        gifFpsPopup.selectItem(
            at: Self.gifFpsOptions.firstIndex(of: Self.gifFpsRecommended) ?? 0)

        gifCompressionPopup.addItems(withTitles: Self.gifCompressionOptions.map {
            $0.lossy == 80 ? "\($0.title) (Recommended)" : $0.title
        })
        // Default to Balanced when gifsicle is around; otherwise None so a
        // fresh install converts without an error out of the box.
        let hasGifsicle = ToolRunner.find("gifsicle") != nil
        gifCompressionPopup.selectItem(at: hasGifsicle ? 1 : 0)
        if !hasGifsicle {
            gifCompressionPopup.toolTip =
                "Balanced/Strong need gifsicle — install with: brew install gifsicle"
        }

        gifFpsPopup.target = self
        gifFpsPopup.action = #selector(gifSettingChanged)
        gifColorsPopup.target = self
        gifColorsPopup.action = #selector(gifSettingChanged)
        gifCompressionPopup.target = self
        gifCompressionPopup.action = #selector(gifSettingChanged)
        gifWidthField.delegate = self
        gifTargetField.delegate = self

        for field in [gifWidthField, gifTargetField] {
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        gifTargetField.placeholderString = "—"

        gifOriginalLabel.textColor = .secondaryLabelColor
        gifOriginalLabel.font = .systemFont(ofSize: 12)
        gifEstimateLabel.textColor = .secondaryLabelColor
        gifEstimateLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let row = NSStackView(views: [
            makeLabel("Width"), gifWidthField,
            makeLabel("FPS"), gifFpsPopup,
            makeLabel("Colors"), gifColorsPopup,
            makeLabel("Compression"), gifCompressionPopup,
            makeLabel("Max MB"), gifTargetField,
        ])
        row.orientation = .horizontal
        row.spacing = 6

        let rows = NSStackView(views: [gifOriginalLabel, row, gifEstimateLabel])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8

        loadVideoInfo()
        return section("Video → GIF", content: rows)
    }

    /// Read the first video's metadata off the main thread, then show the
    /// original-size line and the initial GIF estimate.
    private func loadVideoInfo() {
        guard let first = videos.first else { return }
        Task { [weak self] in
            do {
                let info = try await VideoProbe.info(for: first)
                await MainActor.run { self?.videoInfoLoaded(info) }
            } catch {
                await MainActor.run {
                    self?.gifOriginalLabel.stringValue =
                        "Original: unavailable (\(error.localizedDescription))"
                }
            }
        }
    }

    private func videoInfoLoaded(_ info: VideoInfo) {
        videoInfo = info
        var text = "Original: \(GifProcessor.format(bytes: info.fileBytes))"
            + " · \(info.pixelSize.width) × \(info.pixelSize.height) px"
            + " · " + String(format: "%.1f s", info.duration)
        if videos.count > 1 { text += "  (first of \(videos.count) videos)" }
        gifOriginalLabel.stringValue = text
        updateGifEstimate()
        refreshWindowSize()
    }

    /// Live "Estimated GIF: ~X MB" readout, recomputed on every settings
    /// change. Multi-video drops estimate the first video only.
    private func updateGifEstimate() {
        guard let info = videoInfo else { return }
        let settings = currentGifSettings()
        let bytes = GifProcessor.estimatedBytes(settings: settings,
                                                source: info.pixelSize,
                                                duration: info.duration)
        var text = "Estimated GIF: ~\(GifProcessor.format(bytes: bytes))"
        if let target = settings.targetBytes, bytes > target {
            text += "  (over max — width will shrink to fit)"
        }
        gifEstimateLabel.stringValue = text
    }

    @objc private func gifSettingChanged() {
        updateGifEstimate()
    }

    /// A section header above its content row. (NSBox draws its title over
    /// the content when sized by fittingSize, so sections are plain stacks.)
    private func section(_ title: String, content: NSView) -> NSView {
        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func makeLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    @objc private func imageModeChanged() {
        let index = imageModePopup.indexOfSelectedItem
        let showPercent = index == 0            // percent
        let showHeight = index == 1 || index == 2  // fit within box / exact
        percentField.isHidden = !showPercent
        percentLabel.isHidden = !showPercent
        percentResultLabel.isHidden = !showPercent
        widthField.isHidden = showPercent
        pxLabel.isHidden = showPercent
        heightField.isHidden = !showHeight
        timesLabel.isHidden = !showHeight
        scaleRow?.isHidden = index != 2         // slider only for exact mode
        refreshWindowSize()
    }

    private func refreshWindowSize() {
        guard let stack = window?.contentView as? NSStackView else { return }
        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(stack.fittingSize)
    }

    // MARK: - Conversion

    private func currentImageMode() -> ResizeMode {
        let percent = Double(percentField.stringValue) ?? 50
        let width = Int(widthField.stringValue) ?? 1280
        let height = Int(heightField.stringValue) ?? 720
        switch imageModePopup.indexOfSelectedItem {
        case 1: return .fit(PixelSize(width: max(width, 1), height: max(height, 1)))
        case 2: return .exact(PixelSize(width: max(width, 1), height: max(height, 1)))
        default: return .percent(max(percent, 1))
        }
    }

    private func currentGifSettings() -> GifSettings {
        let mb = Double(gifTargetField.stringValue)
        let fpsIndex = gifFpsPopup.indexOfSelectedItem
        let fps = Self.gifFpsOptions.indices.contains(fpsIndex)
            ? Self.gifFpsOptions[fpsIndex] : Self.gifFpsRecommended
        let compressionIndex = gifCompressionPopup.indexOfSelectedItem
        let lossy = Self.gifCompressionOptions.indices.contains(compressionIndex)
            ? Self.gifCompressionOptions[compressionIndex].lossy : nil
        return GifSettings(
            width: max(Int(gifWidthField.stringValue) ?? 640, 40),
            fps: fps,
            colors: Int(gifColorsPopup.titleOfSelectedItem ?? "128") ?? 128,
            targetBytes: mb.map { Int($0 * 1_000_000) },
            lossy: lossy
        )
    }

    /// In "Ask for name…" mode, run a save panel per file (on the main
    /// thread, before conversion starts). Returns nil when the user cancels
    /// that file. In auto mode the processors pick a collision-free
    /// random-token name themselves.
    private func askForOutputURL(source: URL) -> URL? {
        let isVideo = FileClassifier.kind(of: source) == .video
        let ext = isVideo ? "gif"
            : (source.pathExtension.isEmpty ? "png" : source.pathExtension)
        let base = source.deletingPathExtension().lastPathComponent

        let panel = NSSavePanel()
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = "\(base)-\(Geometry.randomToken()).\(ext)"
        panel.title = isVideo ? "Save GIF" : "Save Resized Image"
        panel.message = "Choose a name for \(source.lastPathComponent)"
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    @objc private func convertPressed() {
        let askForNames = outputModePopup.indexOfSelectedItem == 1
        var imageJobs: [(source: URL, output: URL?)] = []
        var videoJobs: [(source: URL, output: URL?)] = []
        var skipped = 0

        for url in images {
            if askForNames {
                guard let chosen = askForOutputURL(source: url) else { skipped += 1; continue }
                imageJobs.append((url, chosen))
            } else {
                imageJobs.append((url, nil))
            }
        }
        for url in videos {
            if askForNames {
                guard let chosen = askForOutputURL(source: url) else { skipped += 1; continue }
                videoJobs.append((url, chosen))
            } else {
                videoJobs.append((url, nil))
            }
        }
        if imageJobs.isEmpty, videoJobs.isEmpty {
            setStatus("Nothing to convert — all files skipped")
            return
        }

        convertButton.isEnabled = false
        spinner.startAnimation(nil)
        setStatus("Converting…")

        let imageMode = currentImageMode()
        let gifSettings = currentGifSettings()
        let reveal = revealCheckbox.state == .on
        let skippedCount = skipped

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outputs: [URL] = []
            var failures: [String] = []
            let total = imageJobs.count + videoJobs.count
            var done = 0

            for job in imageJobs {
                do {
                    let result = try ImageProcessor.resize(job.source, mode: imageMode,
                                                           output: job.output)
                    outputs.append(result.output)
                } catch {
                    failures.append("\(job.source.lastPathComponent): \(error.localizedDescription)")
                }
                done += 1
                self?.setStatusAsync("Converting… \(done)/\(total)")
            }
            for job in videoJobs {
                do {
                    let result = try GifProcessor.convert(job.source, settings: gifSettings,
                                                          output: job.output) { note in
                        self?.setStatusAsync("\(job.source.lastPathComponent): \(note)")
                    }
                    outputs.append(result.output)
                    if let target = gifSettings.targetBytes, result.bytes > target {
                        failures.append("\(result.output.lastPathComponent) is "
                            + "\(GifProcessor.format(bytes: result.bytes)) — could not reach target")
                    }
                } catch {
                    failures.append("\(job.source.lastPathComponent): \(error.localizedDescription)")
                }
                done += 1
                self?.setStatusAsync("Converting… \(done)/\(total)")
            }

            DispatchQueue.main.async {
                self?.finish(outputs: outputs, failures: failures,
                             skipped: skippedCount, reveal: reveal)
            }
        }
    }

    private func finish(outputs: [URL], failures: [String], skipped: Int, reveal: Bool) {
        spinner.stopAnimation(nil)
        convertButton.isEnabled = true

        if reveal, !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if failures.isEmpty {
            let sizes = outputs.map { url -> String in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                return GifProcessor.format(bytes: (attrs?[.size] as? Int) ?? 0)
            }
            var text = "Done — \(outputs.count) file\(outputs.count == 1 ? "" : "s")"
            if sizes.count == 1 { text += " (\(sizes[0]))" }
            if skipped > 0 { text += ", \(skipped) skipped" }
            setStatus(text)
        } else {
            setStatus("⚠︎ \(failures.joined(separator: " · "))")
            statusLabel.toolTip = failures.joined(separator: "\n")
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func setStatusAsync(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.setStatus(text) }
    }
}

extension OptionsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        OptionsWindowController.active.removeAll { $0 === self }
    }
}

extension OptionsWindowController: NSTextFieldDelegate {
    /// In exact mode the aspect ratio is locked to the original image:
    /// editing width recomputes height (and vice versa), and the slider
    /// tracks the resulting scale.
    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticFieldUpdate,
              let field = notification.object as? NSTextField else { return }
        if field === percentField {
            updatePercentResult()
            return
        }
        if field === gifWidthField || field === gifTargetField {
            updateGifEstimate()
            return
        }
        guard imageModePopup.indexOfSelectedItem == 2,
              let source = sourcePixelSize,
              field === widthField || field === heightField else { return }

        let aspect = Double(source.width) / Double(source.height)
        isProgrammaticFieldUpdate = true
        if field === widthField, let width = Int(widthField.stringValue), width > 0 {
            heightField.stringValue = String(max(Int((Double(width) / aspect).rounded()), 1))
        } else if field === heightField, let height = Int(heightField.stringValue), height > 0 {
            widthField.stringValue = String(max(Int((Double(height) * aspect).rounded()), 1))
        }
        isProgrammaticFieldUpdate = false

        if let width = Int(widthField.stringValue) {
            let pct = Double(width) / Double(source.width) * 100
            scaleSlider.doubleValue = min(max(pct, scaleSlider.minValue), scaleSlider.maxValue)
            scaleValueLabel.stringValue = "\(Int(pct.rounded()))%"
        }
    }
}
