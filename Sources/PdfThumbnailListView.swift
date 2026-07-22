import AppKit
import PDFKit

/// Scrollable page-thumbnail sidebar built on NSCollectionView. Supports
/// multi-selection and drag-to-reorder, renders thumbnails lazily off the main
/// thread (only visible cells), and draws a rotation badge per page. Chosen
/// over PDFThumbnailView, which offers no multi-select/selection API and whose
/// built-in reorder mutates the bound document behind the model's back.

final class PdfThumbnailListView: NSView {
    /// Supplies the page to render at an index plus a cache key that changes
    /// whenever the page's identity or rotation changes.
    var pageProvider: ((Int) -> (page: PDFPage, key: String)?)?
    var onSelectionChanged: (([Int]) -> Void)?
    var onMove: (([Int], Int) -> Void)?
    /// Move the page at `fromIndex` to a typed 1-based page number.
    var onRenumber: ((_ fromIndex: Int, _ toOneBased: Int) -> Void)?
    /// True while a page-number field is being edited, false when it ends.
    var onNumberEditingChanged: ((Bool) -> Void)?

    private static let dragType = NSPasteboard.PasteboardType("dev.chris.resizer.pdfpage-indexes")
    private static let thumbnailSize = NSSize(width: 120, height: 150)

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()

    private let renderQueue = DispatchQueue(label: "dev.chris.resizer.pdf-thumbnails",
                                            qos: .userInitiated)
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()

    private var pageCount = 0
    private var draggedIndexes: [Int] = []
    private var autoScrollTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setup() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 148, height: 190)
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        layout.minimumLineSpacing = 10
        layout.minimumInteritemSpacing = 10
        layout.scrollDirection = .vertical

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(PdfPageItem.self,
                                forItemWithIdentifier: PdfPageItem.identifier)
        collectionView.registerForDraggedTypes([Self.dragType])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// Replace the whole list (after delete/reorder/undo). Clears rendered
    /// thumbnails' identity guards but keeps the key-based cache, so unchanged
    /// pages redraw from cache instantly.
    func reload(count: Int) {
        pageCount = count
        collectionView.reloadData()
    }

    /// Re-render specific pages (after a rotation changes their appearance).
    func invalidate(indices: [Int]) {
        let paths = Set(indices.map { IndexPath(item: $0, section: 0) })
        guard !paths.isEmpty else { return }
        collectionView.reloadItems(at: paths)
    }

    func select(indices: [Int]) {
        let paths = Set(indices
            .filter { (0..<pageCount).contains($0) }
            .map { IndexPath(item: $0, section: 0) })
        collectionView.selectionIndexPaths = paths
        if let first = paths.min() {
            collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
    }

    // MARK: - Thumbnail rendering

    private func configure(_ item: PdfPageItem, at index: Int) {
        guard let provided = pageProvider?(index) else { return }
        let key = provided.key
        item.renderKey = key
        item.onRenumber = { [weak self] from, to in self?.onRenumber?(from, to) }
        item.onEditingChanged = { [weak self] editing in self?.onNumberEditingChanged?(editing) }
        item.configure(pageNumber: index + 1, rotation: rotationDegrees(from: key))

        if let cached = cache.object(forKey: key as NSString) {
            item.setThumbnail(cached)
            return
        }
        item.setThumbnail(nil)
        let page = provided.page
        renderQueue.async { [weak self, weak item] in
            let image = PdfAssembler.thumbnail(for: page, maxSize: Self.thumbnailSize)
            self?.cache.setObject(image, forKey: key as NSString)
            DispatchQueue.main.async {
                // Only apply if the (reusable) item still wants this exact page.
                guard let item, item.renderKey == key else { return }
                item.setThumbnail(image)
            }
        }
    }

    /// Keys look like "doc-page-rotation-redactHash"; the rotation is the third
    /// component (parsed positionally — the trailing hash is not the rotation).
    private func rotationDegrees(from key: String) -> Int {
        let parts = key.split(separator: "-")
        return parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
    }

    private func reportSelection() {
        let indexes = collectionView.selectionIndexPaths.map { $0.item }.sorted()
        onSelectionChanged?(indexes)
    }

    // MARK: - Drag auto-scroll

    /// NSCollectionView does not auto-scroll during a reorder drag, so a page
    /// can only be dropped within the currently visible range. This timer runs
    /// for the duration of the drag and scrolls the list when the pointer nears
    /// the top or bottom edge, letting a drag reach any position.
    private func startAutoScroll() {
        stopAutoScroll()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.autoScrollTick()
        }
        // A drag runs the run loop in event-tracking mode; the timer must be
        // registered for that mode explicitly or it never fires mid-drag (that
        // was the bug — .common does not reliably include it here).
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private func autoScrollTick() {
        guard let window = collectionView.window, pageCount > 0 else { return }
        let clip = scrollView.contentView

        // Detect the edge in window coordinates (fixed y-up orientation), then
        // scroll the clip view directly for a smooth, steady speed.
        let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let frame = scrollView.convert(scrollView.bounds, to: nil)
        let edge: CGFloat = 40
        let step: CGFloat = 8   // px/tick at ~60fps ≈ 480 px/s — medium speed

        var dy: CGFloat = 0
        if mouse.y >= frame.maxY - edge {            // near the visual top
            dy = collectionView.isFlipped ? -step : step
        } else if mouse.y <= frame.minY + edge {     // near the visual bottom
            dy = collectionView.isFlipped ? step : -step
        }
        guard dy != 0 else { return }

        let maxY = max(0, collectionView.frame.height - clip.bounds.height)
        let newY = min(max(clip.bounds.origin.y + dy, 0), maxY)
        guard newY != clip.bounds.origin.y else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: newY))
        scrollView.reflectScrolledClipView(clip)
    }
}

// MARK: - Data source & delegate

extension PdfThumbnailListView: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        pageCount
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PdfPageItem.identifier,
                                           for: indexPath) as! PdfPageItem
        configure(item, at: indexPath.item)
        return item
    }
}

extension PdfThumbnailListView: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        reportSelection()
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didDeselectItemsAt indexPaths: Set<IndexPath>) {
        reportSelection()
    }

    func collectionView(_ collectionView: NSCollectionView,
                        canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(indexPath.item), forType: Self.dragType)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView,
                        draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint,
                        forItemsAt indexPaths: Set<IndexPath>) {
        draggedIndexes = indexPaths.map { $0.item }.sorted()
        startAutoScroll()
    }

    func collectionView(_ collectionView: NSCollectionView,
                        draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint,
                        dragOperation operation: NSDragOperation) {
        stopAutoScroll()
        draggedIndexes = []
    }

    func collectionView(_ collectionView: NSCollectionView,
                        validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        // Only reordering: insert between items, never drop "on" one.
        if proposedDropOperation.pointee == .on {
            proposedDropOperation.pointee = .before
        }
        return draggedIndexes.isEmpty ? [] : .move
    }

    func collectionView(_ collectionView: NSCollectionView,
                        acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard !draggedIndexes.isEmpty else { return false }
        onMove?(draggedIndexes, indexPath.item)
        draggedIndexes = []
        return true
    }
}

/// One thumbnail cell: page image, an editable page-number field, and a
/// rotation badge. Typing a new number into the field moves the page there.
final class PdfPageItem: NSCollectionViewItem, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("PdfPageItem")

    /// The cache key of the page this (reusable) item currently represents;
    /// used to discard stale async thumbnail renders.
    var renderKey: String?
    /// The page's current 0-based position, read when the user commits a new
    /// page number.
    var displayIndex = 0
    /// Called when the user types and commits a new 1-based page number.
    var onRenumber: ((_ fromIndex: Int, _ toOneBased: Int) -> Void)?
    /// Called when this cell's page-number field starts (true) and ends (false)
    /// editing, so the window can suspend its default (Export) button.
    var onEditingChanged: ((Bool) -> Void)?

    private let thumbnail = NSImageView()
    private let numberField = NSTextField()
    private let okButton = NSButton()
    private let badge = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 2
        container.layer?.borderColor = NSColor.clear.cgColor
        view = container

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.wantsLayer = true
        thumbnail.layer?.borderWidth = 1
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(thumbnail)

        numberField.isEditable = true
        numberField.isBordered = true
        numberField.bezelStyle = .roundedBezel
        numberField.controlSize = .small
        numberField.alignment = .center
        numberField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        numberField.delegate = self
        numberField.toolTip = "Type a page number to move this page there"
        numberField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(numberField)

        // Confirm button shown only while the field is being edited.
        okButton.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                 accessibilityDescription: "OK")
        okButton.imagePosition = .imageOnly
        okButton.isBordered = false
        okButton.contentTintColor = .controlAccentColor
        okButton.toolTip = "Move this page to the typed number"
        okButton.target = self
        okButton.action = #selector(okPressed)
        okButton.isHidden = true
        okButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(okButton)

        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 7
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badge)

        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            thumbnail.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            thumbnail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            thumbnail.bottomAnchor.constraint(equalTo: numberField.topAnchor, constant: -4),

            numberField.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            numberField.widthAnchor.constraint(equalToConstant: 52),
            numberField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),

            // OK sits to the right of the (centered) field so showing it never
            // shifts the field.
            okButton.leadingAnchor.constraint(equalTo: numberField.trailingAnchor, constant: 4),
            okButton.centerYAnchor.constraint(equalTo: numberField.centerYAnchor),
            okButton.widthAnchor.constraint(equalToConstant: 18),
            okButton.heightAnchor.constraint(equalToConstant: 18),

            badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            badge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            badge.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    private func updateSelectionAppearance() {
        view.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        view.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    func configure(pageNumber: Int, rotation: Int) {
        displayIndex = pageNumber - 1
        let editing = numberField.currentEditor() != nil
        // Don't stomp what the user is currently typing.
        if !editing {
            numberField.stringValue = String(pageNumber)
        }
        okButton.isHidden = !editing
        if rotation == 0 {
            badge.isHidden = true
        } else {
            badge.isHidden = false
            badge.stringValue = "\(rotation)°"
        }
        updateSelectionAppearance()
    }

    func setThumbnail(_ image: NSImage?) {
        thumbnail.image = image
    }

    /// Force-commit the field when the OK button is clicked: resigning the field
    /// editor ends editing, which runs `controlTextDidEndEditing`.
    @objc private func okPressed() {
        view.window?.makeFirstResponder(nil)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        okButton.isHidden = false
        onEditingChanged?(true)
    }

    /// Commit a typed page number on Enter, Tab, click-away, or OK. Reverts junk
    /// or no-op input; a valid new number is dispatched so the list can reload
    /// after the field editor has finished tearing down.
    func controlTextDidEndEditing(_ obj: Notification) {
        okButton.isHidden = true
        onEditingChanged?(false)
        let trimmed = numberField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value != displayIndex + 1 else {
            numberField.stringValue = String(displayIndex + 1)
            return
        }
        let from = displayIndex
        DispatchQueue.main.async { [weak self] in self?.onRenumber?(from, value) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        renderKey = nil
        thumbnail.image = nil
        badge.isHidden = true
        okButton.isHidden = true
    }
}
