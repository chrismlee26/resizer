import AppKit
import UniformTypeIdentifiers

/// View layered over the status item button. Accepts file drags (with a
/// highlight while hovering) and forwards clicks so the menu still opens.

final class DropView: NSView {
    var onFiles: (([URL]) -> Void)?
    var onClick: (() -> Void)?

    private var isReceivingDrag = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard isReceivingDrag else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                     xRadius: 4, yRadius: 4).fill()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = !FileClassifier.urls(from: sender).isEmpty
        isReceivingDrag = accepted
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingDrag = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isReceivingDrag = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isReceivingDrag = false
        let urls = FileClassifier.urls(from: sender)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Fallback drop target: the status item's window itself. NSWindow forwards
/// NSDraggingDestination messages to its delegate, so registering the window
/// catches drops even if the overlay view isn't hit (belt and suspenders for
/// OS versions where status item subviews don't receive drags).
final class WindowDropProxy: NSObject, NSWindowDelegate, NSDraggingDestination {
    var onFiles: (([URL]) -> Void)?

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileClassifier.urls(from: sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileClassifier.urls(from: sender)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }
}

enum FileKind {
    case image
    case video
    case pdf
}

enum FileClassifier {
    static func kind(of url: URL) -> FileKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return nil
        }
        // PDF first: it conforms to neither .movie nor .image, but be explicit.
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    /// Extract the droppable (image/video/pdf) file URLs from a drag session.
    static func urls(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: options) as? [URL] ?? []
        return urls.filter { kind(of: $0) != nil }
    }
}
