import Foundation

/// Pure page-list editing logic — no PDFKit, no AppKit, fully unit-testable.
/// The editor's on-screen document and the exported file are both assembled
/// from this list; this type only tracks *which* source page goes where and
/// how far it has been rotated.

/// A redaction box in unrotated mediaBox page space (PDF points, origin
/// bottom-left). Stored rotation-independent so it stays glued to content
/// no matter how the page is rotated afterwards.
struct RedactRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// One page of the working document: which dropped document it came from,
/// which page within that document, the rotation applied in the editor
/// (a delta on top of the source page's own rotation, always 0/90/180/270),
/// and any redaction boxes drawn on it.
struct PageRef: Equatable {
    let docIndex: Int
    let pageIndex: Int
    var rotationDelta: Int = 0
    var redactions: [RedactRect] = []
}

struct PdfEditModel: Equatable {
    private(set) var pages: [PageRef]
    private let original: [PageRef]
    private var undoStack: [[PageRef]] = []

    private static let maxUndo = 50

    /// Build the initial list by concatenating every source document's pages
    /// in drop order — this is the "combine multiple PDFs" behaviour.
    init(pageCounts: [Int]) {
        var refs: [PageRef] = []
        for (docIndex, count) in pageCounts.enumerated() where count > 0 {
            for pageIndex in 0..<count {
                refs.append(PageRef(docIndex: docIndex, pageIndex: pageIndex))
            }
        }
        pages = refs
        original = refs
    }

    var count: Int { pages.count }
    var isEmpty: Bool { pages.isEmpty }
    var isDirty: Bool { pages != original }
    var canUndo: Bool { !undoStack.isEmpty }

    /// Append pages for newly added source documents to the bottom of the list.
    /// `startDocIndex` is where the first new document sits in the controller's
    /// sources array. Existing source indices never change, so prior undo
    /// snapshots stay valid. Returns the index of the first appended page (equal
    /// to the old count; nothing was appended when it equals the new count).
    @discardableResult
    mutating func appendPages(startDocIndex: Int, pageCounts: [Int]) -> Int {
        let firstNew = pages.count
        var newRefs: [PageRef] = []
        for (offset, count) in pageCounts.enumerated() where count > 0 {
            for pageIndex in 0..<count {
                newRefs.append(PageRef(docIndex: startDocIndex + offset, pageIndex: pageIndex))
            }
        }
        guard !newRefs.isEmpty else { return firstNew }
        snapshot()
        pages.append(contentsOf: newRefs)
        return firstNew
    }

    /// Rotate the given selection by `degrees` (typically ±90). No-op if the
    /// selection is empty or entirely out of range.
    mutating func rotate(_ indices: Set<Int>, by degrees: Int) {
        let valid = indices.filter { pages.indices.contains($0) }
        guard !valid.isEmpty, degrees % 360 != 0 else { return }
        snapshot()
        for i in valid {
            pages[i].rotationDelta = Self.normalizedRotation(pages[i].rotationDelta + degrees)
        }
    }

    /// Add a redaction box to a page. No-op (no undo entry) for an out-of-range
    /// index or a degenerate rect.
    mutating func addRedaction(_ rect: RedactRect, at index: Int) {
        guard pages.indices.contains(index), rect.width > 0, rect.height > 0 else { return }
        snapshot()
        pages[index].redactions.append(rect)
    }

    /// Remove every redaction from the given pages. No-op unless at least one
    /// valid index actually has redactions (avoids a junk undo entry).
    mutating func clearRedactions(at indices: Set<Int>) {
        let toClear = indices.filter { pages.indices.contains($0) && !pages[$0].redactions.isEmpty }
        guard !toClear.isEmpty else { return }
        snapshot()
        for i in toClear { pages[i].redactions.removeAll() }
    }

    func hasRedactions(at index: Int) -> Bool {
        pages.indices.contains(index) && !pages[index].redactions.isEmpty
    }

    var redactedPageCount: Int {
        pages.reduce(0) { $0 + ($1.redactions.isEmpty ? 0 : 1) }
    }

    /// Delete the given selection. Returns the index to select afterwards —
    /// the item that slid into the first deleted slot, clamped — or 0 when the
    /// list becomes empty.
    @discardableResult
    mutating func delete(_ indices: Set<Int>) -> Int {
        let valid = indices.filter { pages.indices.contains($0) }
        guard !valid.isEmpty else { return 0 }
        snapshot()
        let firstDeleted = valid.min()!
        for i in valid.sorted(by: >) { pages.remove(at: i) }
        guard !pages.isEmpty else { return 0 }
        return min(firstDeleted, pages.count - 1)
    }

    /// Reorder a multi-selection to a drop point. `destination` is an index
    /// into the *current* list meaning "insert before the item now there"
    /// (or == count for the end). Returns the moved pages' new indices, in
    /// order. Moved pages keep their relative order.
    @discardableResult
    mutating func move(_ indices: [Int], to destination: Int) -> [Int] {
        let sorted = indices.filter { pages.indices.contains($0) }.sorted()
        guard !sorted.isEmpty, (0...pages.count).contains(destination) else {
            return sorted
        }
        let moving = sorted.map { pages[$0] }
        // Removing items that sit before the drop point shifts it left.
        let removedBefore = sorted.filter { $0 < destination }.count
        let insertAt = destination - removedBefore

        var newPages = pages
        for i in sorted.reversed() { newPages.remove(at: i) }
        newPages.insert(contentsOf: moving, at: insertAt)

        let newIndices = Array(insertAt..<(insertAt + moving.count))
        if newPages != pages {
            snapshot()
            pages = newPages
        }
        return newIndices
    }

    /// Move a single page to an exact 0-based position — the "type a new page
    /// number" gesture (e.g. changing page 13 to 1 puts it first and pushes the
    /// rest down). The target is clamped into range. Returns the page's final
    /// index; a no-op (same position) makes no undo entry.
    @discardableResult
    mutating func moveToIndex(_ from: Int, to target: Int) -> Int {
        guard pages.indices.contains(from) else { return from }
        let clamped = min(max(target, 0), pages.count - 1)
        guard clamped != from else { return from }
        snapshot()
        let page = pages.remove(at: from)
        pages.insert(page, at: clamped)
        return clamped
    }

    /// The pages at the given indices, in page order (not click/selection
    /// order) — used to assemble an "extract selected pages" document.
    func refs(at indices: [Int]) -> [PageRef] {
        indices.filter { pages.indices.contains($0) }
            .sorted()
            .map { pages[$0] }
    }

    /// Undo the most recent mutation. Returns false when nothing to undo.
    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        pages = previous
        return true
    }

    /// Restore the initial (as-dropped) page list. Undoable.
    mutating func revert() {
        guard pages != original else { return }
        snapshot()
        pages = original
    }

    /// Normalize any degree value into 0/90/180/270, handling negatives
    /// (PDFKit does not): -90 → 270, 270 + 90 → 0.
    static func normalizedRotation(_ degrees: Int) -> Int {
        let r = degrees % 360
        return r < 0 ? r + 360 : r
    }

    private mutating func snapshot() {
        undoStack.append(pages)
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
    }
}
