import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let windowDropProxy = WindowDropProxy()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let handleFiles: ([URL]) -> Void = { urls in
            OptionsWindowController.present(urls: urls)
        }

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left.rectangle",
                                accessibilityDescription: "Resizer")
            image?.isTemplate = true
            button.image = image

            // Pin with constraints — the button's bounds are not laid out yet
            // at launch, so a frame-based subview can end up zero-sized and
            // never receive drags.
            let dropView = DropView(frame: .zero)
            dropView.translatesAutoresizingMaskIntoConstraints = false
            dropView.onFiles = handleFiles
            dropView.onClick = { [weak self] in self?.showMenu() }
            button.addSubview(dropView)
            NSLayoutConstraint.activate([
                dropView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                dropView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                dropView.topAnchor.constraint(equalTo: button.topAnchor),
                dropView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }

        // Fallback: also accept drops at the status item window level.
        windowDropProxy.onFiles = handleFiles
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.statusItem.button?.window else { return }
            window.registerForDraggedTypes([.fileURL])
            if window.delegate == nil {
                window.delegate = self.windowDropProxy
            }
        }

        buildMenu()
    }

    /// Files dropped on the app icon in Finder / opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        let usable = urls.filter { FileClassifier.kind(of: $0) != nil }
        if !usable.isEmpty {
            OptionsWindowController.present(urls: usable)
        }
    }

    private func buildMenu() {
        menu.delegate = self
        let openItem = NSMenuItem(title: "Open Files…", action: #selector(openFiles),
                                  keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let hint = NSMenuItem(title: "Drag photos or videos onto the menu bar icon",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Resizer",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    /// The drop view swallows clicks, so pop the menu manually: attach it,
    /// synthesize a click, then detach in menuDidClose so drags keep working.
    private func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .video]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            OptionsWindowController.present(urls: panel.urls)
        }
    }
}
