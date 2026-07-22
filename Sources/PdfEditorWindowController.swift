import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The interactive PDF editor window: a thumbnail sidebar next to a full-page
/// preview, with rotate / delete / extract / reorder / undo, and export to a
/// chosen filename. Multiple dropped PDFs open here concatenated (combine).
/// Every edit updates a pure `PdfEditModel`; the on-screen `workingDoc` mirrors
/// it and the export is assembled fresh from the source documents.

final class PdfEditorWindowController: NSWindowController {
    private var sources: [PDFDocument]
    private var sourceURLs: [URL]
    private var model: PdfEditModel
    private var workingDoc: PDFDocument
    private var selection: [Int] = []
    /// Guards the two-way selection sync between sidebar and preview.
    private var isSyncingSelection = false

    private let thumbnailList = PdfThumbnailListView()
    private let pdfView = PDFView()
    private let previewContainer = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No pages — use Revert to start over")
    private var redactOverlay: PdfRedactOverlayView?

    private let addButton = NSButton()
    private let rotateLeftButton = NSButton()
    private let rotateRightButton = NSButton()
    private let deleteButton = NSButton()
    private let extractButton = NSButton()
    private let redactButton = NSButton()
    private let clearRedactionsButton = NSButton()
    private let undoButton = NSButton()
    private let revertButton = NSButton()
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let selectionLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let revealCheckbox = NSButton(checkboxWithTitle: "Reveal in Finder when done",
                                          target: nil, action: nil)

    /// Keeps controllers alive while their window is open.
    private static var active: [PdfEditorWindowController] = []

    // MARK: - Presentation

    static func present(urls: [URL]) {
        var sources: [PDFDocument] = []
        var usedURLs: [URL] = []
        var skipped: [String] = []

        for url in urls {
            switch PdfAssembler.load(url: url) {
            case .ok(let doc):
                sources.append(doc); usedURLs.append(url)
            case .locked(let doc):
                if unlock(doc, url: url) { sources.append(doc); usedURLs.append(url) }
                else { skipped.append(url.lastPathComponent) }
            case .unreadable:
                skipped.append(url.lastPathComponent)
            }
        }

        guard PdfAssembler.pageCounts(of: sources).reduce(0, +) > 0 else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t open PDF"
            alert.informativeText = skipped.isEmpty
                ? "No readable pages were found."
                : "Skipped: \(skipped.joined(separator: ", "))"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        let controller = PdfEditorWindowController(sources: sources, urls: usedURLs)
        active.append(controller)
        AppActivation.windowOpened()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        if !skipped.isEmpty {
            controller.setStatus("Skipped \(skipped.count): \(skipped.joined(separator: ", "))")
        }
    }

    /// Prompt for a locked document's password, retrying until unlocked or the
    /// user skips it. Returns true when the document is unlocked.
    private static func unlock(_ doc: PDFDocument, url: URL) -> Bool {
        while true {
            let alert = NSAlert()
            alert.messageText = "Password required"
            alert.informativeText = "“\(url.lastPathComponent)” is password-protected."
            alert.addButton(withTitle: "Unlock")
            alert.addButton(withTitle: "Skip")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            alert.accessoryView = field
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if doc.unlock(withPassword: field.stringValue) { return true }
        }
    }

    private init(sources: [PDFDocument], urls: [URL]) {
        let model = PdfEditModel(pageCounts: PdfAssembler.pageCounts(of: sources))
        self.sources = sources
        self.sourceURLs = urls
        self.model = model
        self.workingDoc = PdfAssembler.makeDocument(sources: sources, refs: model.pages,
                                                    flattenRedactions: false)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        let first = urls.first?.lastPathComponent ?? "PDF"
        window.title = urls.count > 1 ? "PDF Editor — \(first) +\(urls.count - 1) more"
                                      : "PDF Editor — \(first)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 480)
        super.init(window: window)
        window.delegate = self

        // Accept PDFs/images dragged from Finder anywhere over the window —
        // same effect as the Add PDF/Image button.
        let dropView = FileDropView()
        dropView.onFiles = { [weak self] urls in self?.addFiles(urls: urls) }
        window.contentView = dropView

        buildUI()
        window.center()

        pdfView.document = workingDoc
        thumbnailList.reload(count: model.count)
        if let page = workingDoc.page(at: 0) {
            pdfView.go(to: page)
            selection = [0]
            thumbnailList.select(indices: [0])
        }
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let toolbar = buildToolbarRow()
        let split = buildSplitView()
        let bottom = buildBottomRow()
        for view in [toolbar, split, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),

            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func buildToolbarRow() -> NSView {
        configure(addButton, title: "Add PDF/Image", symbol: "plus",
                  action: #selector(addFilesPressed))
        configure(rotateLeftButton, title: "Rotate Left", symbol: "rotate.left",
                  action: #selector(rotateLeftPressed))
        configure(rotateRightButton, title: "Rotate Right", symbol: "rotate.right",
                  action: #selector(rotateRightPressed))
        configure(deleteButton, title: "Delete", symbol: "trash",
                  action: #selector(deletePressed))
        configure(extractButton, title: "Extract…", symbol: "square.and.arrow.up",
                  action: #selector(extractPressed))
        configure(redactButton, title: "Redact", symbol: "eye.slash",
                  action: #selector(toggleRedactMode))
        redactButton.setButtonType(.pushOnPushOff)
        configure(clearRedactionsButton, title: "Clear Redactions", symbol: "eye",
                  action: #selector(clearRedactionsPressed))
        configure(undoButton, title: "Undo", symbol: "arrow.uturn.backward",
                  action: #selector(undoPressed))
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = .command
        configure(revertButton, title: "Revert", symbol: "arrow.counterclockwise",
                  action: #selector(revertPressed))

        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.font = .systemFont(ofSize: 12)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [
            addButton, separator(),
            rotateLeftButton, rotateRightButton, deleteButton, extractButton,
            redactButton, clearRedactionsButton,
            separator(), undoButton, revertButton, spacer, selectionLabel,
        ])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    private func buildSplitView() -> NSView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        thumbnailList.translatesAutoresizingMaskIntoConstraints = false
        thumbnailList.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        thumbnailList.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        thumbnailList.pageProvider = { [weak self] index in
            guard let self, self.model.pages.indices.contains(index),
                  let page = self.workingDoc.page(at: index) else { return nil }
            let ref = self.model.pages[index]
            return (page, self.cacheKey(for: ref))
        }
        thumbnailList.onSelectionChanged = { [weak self] indexes in
            self?.selectionChanged(indexes)
        }
        thumbnailList.onMove = { [weak self] indexes, destination in
            self?.movePages(indexes, to: destination)
        }
        thumbnailList.onRenumber = { [weak self] from, toOneBased in
            self?.renumberPage(from: from, toOneBased: toOneBased)
        }
        // While a page-number field is being edited, drop Export's Return key
        // equivalent so Enter commits the number instead of starting an export.
        thumbnailList.onNumberEditingChanged = { [weak self] editing in
            self?.exportButton.keyEquivalent = editing ? "" : "\r"
        }

        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        // Let file drops fall through to the window's FileDropView instead of
        // PDFView trying to open the dropped file itself.
        pdfView.unregisterDraggedTypes()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(pdfView)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
        ])

        split.addArrangedSubview(thumbnailList)
        split.addArrangedSubview(previewContainer)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(pdfPageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        DispatchQueue.main.async { split.setPosition(190, ofDividerAt: 0) }
        return split
    }

    private func buildBottomRow() -> NSView {
        exportButton.target = self
        exportButton.action = #selector(exportPressed)
        exportButton.keyEquivalent = "\r"
        exportButton.bezelStyle = .rounded

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        revealCheckbox.state = .on

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [
            statusLabel, spinner, spacer, revealCheckbox, exportButton,
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func configure(_ button: NSButton, title: String, symbol: String,
                           action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = action
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }

    // MARK: - Selection sync

    private func selectionChanged(_ indexes: [Int]) {
        selection = indexes
        updateControls()
        guard !isSyncingSelection, let first = indexes.first,
              let page = workingDoc.page(at: first) else { return }
        isSyncingSelection = true
        pdfView.go(to: page)
        isSyncingSelection = false
    }

    /// When the preview scrolls to a new page, mirror it into the sidebar —
    /// but only for a single/empty selection, so a multi-select built for a
    /// batch operation is not stomped.
    @objc private func pdfPageChanged() {
        guard !isSyncingSelection, let current = pdfView.currentPage else { return }
        let index = workingDoc.index(for: current)
        guard index >= 0, index != NSNotFound, selection.count <= 1,
              selection.first != index else { return }
        isSyncingSelection = true
        thumbnailList.select(indices: [index])
        selection = [index]
        updateControls()
        isSyncingSelection = false
    }

    // MARK: - Operations

    /// Add more PDFs and/or images via the open panel.
    @objc private func addFilesPressed() {
        exitRedactMode()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]
        panel.title = "Add PDF or Image"
        panel.directoryURL = sourceURLs.first?.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addFiles(urls: panel.urls)
    }

    /// Append PDFs and/or images (from the Add panel or a Finder drop) to the
    /// bottom of the list. Images become one-page documents.
    private func addFiles(urls: [URL]) {
        exitRedactMode()
        var newDocs: [PDFDocument] = []
        var newURLs: [URL] = []
        var skipped: [String] = []
        for url in urls {
            switch FileClassifier.kind(of: url) {
            case .pdf:
                switch PdfAssembler.load(url: url) {
                case .ok(let doc):
                    newDocs.append(doc); newURLs.append(url)
                case .locked(let doc):
                    if Self.unlock(doc, url: url) { newDocs.append(doc); newURLs.append(url) }
                    else { skipped.append(url.lastPathComponent) }
                case .unreadable:
                    skipped.append(url.lastPathComponent)
                }
            case .image:
                if let doc = PdfAssembler.documentFromImage(url: url) {
                    newDocs.append(doc); newURLs.append(url)
                } else { skipped.append(url.lastPathComponent) }
            default:
                skipped.append(url.lastPathComponent)
            }
        }

        guard !newDocs.isEmpty else {
            setStatus(skipped.isEmpty ? "Nothing added"
                                     : "Couldn’t add: \(skipped.joined(separator: ", "))")
            return
        }

        let startDocIndex = sources.count
        sources.append(contentsOf: newDocs)
        sourceURLs.append(contentsOf: newURLs)
        let firstNew = model.appendPages(startDocIndex: startDocIndex,
                                         pageCounts: newDocs.map { $0.pageCount })

        rebuildWorkingDocument()
        thumbnailList.reload(count: model.count)
        let added = model.count - firstNew
        if model.pages.indices.contains(firstNew) {
            selection = [firstNew]
            thumbnailList.select(indices: [firstNew])
            goTo(index: firstNew)
        }
        updateControls()

        var message = "Added \(added) page\(added == 1 ? "" : "s")"
        if !skipped.isEmpty { message += ", skipped \(skipped.count)" }
        setStatus(message)
    }

    @objc private func rotateLeftPressed() { rotate(by: -90) }
    @objc private func rotateRightPressed() { rotate(by: 90) }

    private func rotate(by degrees: Int) {
        guard !selection.isEmpty else { return }
        model.rotate(Set(selection), by: degrees)
        for index in selection where model.pages.indices.contains(index) {
            let ref = model.pages[index]
            let sourceRotation = sources[ref.docIndex].page(at: ref.pageIndex)?.rotation ?? 0
            workingDoc.page(at: index)?.rotation =
                PdfEditModel.normalizedRotation(sourceRotation + ref.rotationDelta)
        }
        pdfView.layoutDocumentView()
        thumbnailList.invalidate(indices: selection)
        updateControls()
    }

    @objc private func deletePressed() {
        guard !selection.isEmpty else { return }
        let next = model.delete(Set(selection))
        rebuildWorkingDocument()
        thumbnailList.reload(count: model.count)
        if model.isEmpty {
            selection = []
            thumbnailList.select(indices: [])
        } else {
            selection = [next]
            thumbnailList.select(indices: [next])
            goTo(index: next)
        }
        updateControls()
    }

    private func movePages(_ indexes: [Int], to destination: Int) {
        let newIndices = model.move(indexes, to: destination)
        rebuildWorkingDocument()
        thumbnailList.reload(count: model.count)
        selection = newIndices
        thumbnailList.select(indices: newIndices)
        if let first = newIndices.first { goTo(index: first) }
        updateControls()
    }

    /// Move a single page to a typed 1-based page number (e.g. change 13 to 1).
    private func renumberPage(from: Int, toOneBased: Int) {
        guard model.pages.indices.contains(from) else { return }
        let landed = model.moveToIndex(from, to: toOneBased - 1)
        guard landed != from else { return }
        rebuildWorkingDocument()
        thumbnailList.reload(count: model.count)
        selection = [landed]
        thumbnailList.select(indices: [landed])
        goTo(index: landed)
        updateControls()
    }

    @objc private func undoPressed() {
        guard model.undo() else { return }
        afterHistoryChange()
    }

    @objc private func revertPressed() {
        model.revert()
        afterHistoryChange()
    }

    private func afterHistoryChange() {
        rebuildWorkingDocument()
        thumbnailList.reload(count: model.count)
        selection = []
        thumbnailList.select(indices: [])
        goTo(index: 0)
        updateControls()
    }

    private func rebuildWorkingDocument() {
        workingDoc = PdfAssembler.makeDocument(sources: sources, refs: model.pages,
                                               flattenRedactions: false)
        pdfView.document = workingDoc
    }

    /// Cache key for a page's thumbnail; changes whenever anything that alters
    /// the rendered pixels changes (rotation or redactions). Format:
    /// "doc-page-rotation-redactHash".
    private func cacheKey(for ref: PageRef) -> String {
        var hasher = Hasher()
        for rect in ref.redactions {
            hasher.combine(rect.x); hasher.combine(rect.y)
            hasher.combine(rect.width); hasher.combine(rect.height)
        }
        let redactHash = UInt(bitPattern: hasher.finalize())
        return "\(ref.docIndex)-\(ref.pageIndex)-\(ref.rotationDelta)-\(redactHash)"
    }

    // MARK: - Redaction

    @objc private func toggleRedactMode() {
        if redactOverlay == nil { enterRedactMode() } else { exitRedactMode() }
    }

    private func enterRedactMode() {
        guard !model.isEmpty else { redactButton.state = .off; return }
        let overlay = PdfRedactOverlayView()
        overlay.pdfView = pdfView
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onRedact = { [weak self] page, rect in self?.handleRedact(page: page, rect: rect) }
        overlay.onExit = { [weak self] in self?.exitRedactMode() }
        previewContainer.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
        ])
        redactOverlay = overlay
        redactButton.state = .on
        window?.makeFirstResponder(overlay)
        setStatus("Redact mode — drag to draw black boxes. Esc to finish.")
    }

    private func exitRedactMode() {
        redactOverlay?.removeFromSuperview()
        redactOverlay = nil
        redactButton.state = .off
        window?.makeFirstResponder(pdfView)
    }

    private func handleRedact(page: PDFPage, rect: CGRect) {
        let index = workingDoc.index(for: page)
        guard index >= 0, index != NSNotFound else { return }
        model.addRedaction(RedactRect(x: rect.origin.x, y: rect.origin.y,
                                      width: rect.width, height: rect.height), at: index)
        PdfAssembler.addPreviewAnnotations(
            [RedactRect(x: rect.origin.x, y: rect.origin.y,
                        width: rect.width, height: rect.height)],
            to: page)
        pdfView.layoutDocumentView()
        thumbnailList.invalidate(indices: [index])
        updateControls()
    }

    @objc private func clearRedactionsPressed() {
        let redactedInSelection = selection.filter { model.hasRedactions(at: $0) }
        guard !redactedInSelection.isEmpty else { return }
        let keep = selection
        model.clearRedactions(at: Set(selection))
        rebuildWorkingDocument()
        thumbnailList.reload(count: model.count)
        selection = keep.filter { model.pages.indices.contains($0) }
        thumbnailList.select(indices: selection)
        updateControls()
    }

    private func goTo(index: Int) {
        guard workingDoc.pageCount > 0 else { return }
        let clamped = min(max(index, 0), workingDoc.pageCount - 1)
        if let page = workingDoc.page(at: clamped) { pdfView.go(to: page) }
    }

    // MARK: - Export & extract

    @objc private func exportPressed() {
        guard !model.isEmpty else { return }
        let base = sourceURLs.first?.deletingPathExtension().lastPathComponent ?? "document"
        guard let url = savePanelURL(defaultName: "\(base)-edited-\(Geometry.randomToken()).pdf",
                                     title: "Export PDF") else { return }
        writeDocument(refs: model.pages, to: url, verb: "Exported")
    }

    @objc private func extractPressed() {
        guard !selection.isEmpty else { return }
        let refs = model.refs(at: selection)
        let base = sourceURLs.first?.deletingPathExtension().lastPathComponent ?? "document"
        guard let url = savePanelURL(defaultName: "\(base)-pages-\(Geometry.randomToken()).pdf",
                                     title: "Extract \(refs.count) Page\(refs.count == 1 ? "" : "s")")
        else { return }
        writeDocument(refs: refs, to: url, verb: "Extracted")
    }

    /// Run a save panel and reject a destination that would overwrite a source.
    private func savePanelURL(defaultName: String, title: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = sourceURLs.first?.deletingLastPathComponent()
        panel.nameFieldStringValue = defaultName
        panel.title = title
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if sourceURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            setStatus("⚠︎ Choose a different name — that would overwrite a source PDF")
            return nil
        }
        return url
    }

    private func writeDocument(refs: [PageRef], to url: URL, verb: String) {
        exitRedactMode()
        setEditingEnabled(false)
        spinner.startAnimation(nil)
        setStatus("Writing…")
        let reveal = revealCheckbox.state == .on
        let flattened = refs.reduce(0) { $0 + ($1.redactions.isEmpty ? 0 : 1) }
        let sources = self.sources
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: URL?
            var errorText: String?
            do {
                try PdfAssembler.write(sources: sources, refs: refs, to: url)
                result = url
            } catch {
                errorText = error.localizedDescription
            }
            DispatchQueue.main.async {
                self?.finishWrite(result: result, error: errorText, verb: verb,
                                  reveal: reveal, flattened: flattened)
            }
        }
    }

    private func finishWrite(result: URL?, error: String?, verb: String,
                             reveal: Bool, flattened: Int) {
        spinner.stopAnimation(nil)
        setEditingEnabled(true)
        updateControls()
        if let url = result {
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            var text = "\(verb) \(url.lastPathComponent)"
            if flattened > 0 {
                text += " (\(flattened) page\(flattened == 1 ? "" : "s") flattened for redaction)"
            }
            setStatus(text)
        } else {
            setStatus("⚠︎ \(error ?? "Write failed")")
        }
    }

    // MARK: - State

    private func updateControls() {
        let hasSelection = !selection.isEmpty
        rotateLeftButton.isEnabled = hasSelection
        rotateRightButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        extractButton.isEnabled = hasSelection
        clearRedactionsButton.isEnabled = selection.contains { model.hasRedactions(at: $0) }
        undoButton.isEnabled = model.canUndo
        revertButton.isEnabled = model.isDirty
        exportButton.isEnabled = !model.isEmpty

        // Leaving no pages exits redact mode and disables the toggle.
        redactButton.isEnabled = !model.isEmpty
        if model.isEmpty, redactOverlay != nil { exitRedactMode() }
        emptyLabel.isHidden = !model.isEmpty

        if model.isEmpty {
            selectionLabel.stringValue = "No pages"
        } else {
            var text = hasSelection
                ? "\(selection.count) of \(model.count) selected"
                : "\(model.count) page\(model.count == 1 ? "" : "s")"
            let redacted = model.redactedPageCount
            if redacted > 0 { text += " · \(redacted) redacted" }
            selectionLabel.stringValue = text
        }
    }

    /// Disable editing while a background write reads the source documents, so
    /// nothing mutates or re-reads them concurrently.
    private func setEditingEnabled(_ enabled: Bool) {
        [addButton, rotateLeftButton, rotateRightButton, deleteButton, extractButton,
         redactButton, clearRedactionsButton,
         undoButton, revertButton, exportButton].forEach { $0.isEnabled = enabled }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }
}

extension PdfEditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: pdfView)
        PdfEditorWindowController.active.removeAll { $0 === self }
        AppActivation.windowClosed()
    }
}
