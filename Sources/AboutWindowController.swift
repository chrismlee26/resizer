import AppKit

/// Small "About Resizer" window: icon, version, a short description, the
/// changelog, and a footer link. The version comes from Info.plist
/// (CFBundleShortVersionString, with the build number stamped from the git
/// commit count by build.sh); the changelog is generated from git history
/// into changelog.txt at build time.

final class AboutWindowController: NSWindowController {
    /// Single instance so repeated menu clicks re-focus the open window.
    private static var shared: AboutWindowController?

    static func present() {
        let isNew = shared == nil
        let controller = shared ?? AboutWindowController()
        shared = controller
        if isNew { AppActivation.windowOpened() }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "About Resizer"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info?["CFBundleVersion"] as? String, build != version else {
            return "Version \(version)"
        }
        return "Version \(version) (build \(build))"
    }

    private static var changelogText: String {
        guard let url = Bundle.main.url(forResource: "changelog", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Changelog unavailable in this build."
        }
        return text
    }

    // MARK: - UI construction

    private func buildUI() {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "Resizer")
        name.font = .boldSystemFont(ofSize: 16)

        let version = NSTextField(labelWithString: Self.versionText)
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor

        let description = NSTextField(wrappingLabelWithString:
            "A tiny menu bar droplet for resizing photos, converting videos "
            + "to GIF or WebP, and editing PDFs. Drag files onto the menu bar "
            + "icon, or use Load File…")
        description.font = .systemFont(ofSize: 12)
        description.alignment = .center
        description.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true

        let header = NSTextField(labelWithString: "CHANGELOG")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let changelog = changelogView()
        let stack = NSStackView(views: [
            icon, name, version, description,
            header, changelog, footerLabel(),
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(14, after: description)
        stack.setCustomSpacing(4, after: header)
        stack.setCustomSpacing(12, after: changelog)

        // With .centerX alignment the edge insets don't survive fittingSize,
        // so pin the width: changelog (380) plus 20pt margins.
        stack.widthAnchor.constraint(equalToConstant: 420).isActive = true

        window?.contentView = stack
        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(stack.fittingSize)
    }

    private func changelogView() -> NSScrollView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        textView.isEditable = false
        textView.string = Self.changelogText
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        return scroll
    }

    /// "chrislee.wtf" opens the site — a selectable label with a .link
    /// attribute is the lightest way to get a clickable link in AppKit.
    private func footerLabel() -> NSTextField {
        let text = "This is a chrislee.wtf project. Free Forever, No Ads, No Tracking."
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if let url = URL(string: "https://chrislee.wtf") {
            let range = (text as NSString).range(of: "chrislee.wtf")
            attributed.addAttributes([.link: url, .foregroundColor: NSColor.linkColor],
                                     range: range)
        }
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = attributed
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        return label
    }
}

extension AboutWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AboutWindowController.shared = nil
        AppActivation.windowClosed()
    }
}
