import PDFKit

/// All PDFKit document plumbing — loading, page copying, assembly, thumbnails.
/// No AppKit UI here. The editor's working document and every exported file are
/// built through `makeDocument`, always from fresh page copies of the sources.

enum PdfAssembler {
    /// Result of trying to open a dropped file.
    enum LoadOutcome {
        case ok(PDFDocument)
        case locked(PDFDocument)   // encrypted — needs unlock(withPassword:)
        case unreadable
    }

    enum AssembleError: Error, LocalizedError {
        case empty
        case writeFailed(URL)

        var errorDescription: String? {
            switch self {
            case .empty: return "No pages to write"
            case .writeFailed(let url): return "Could not write \(url.lastPathComponent)"
            }
        }
    }

    static func load(url: URL) -> LoadOutcome {
        guard let doc = PDFDocument(url: url) else { return .unreadable }
        return doc.isLocked ? .locked(doc) : .ok(doc)
    }

    static func pageCounts(of sources: [PDFDocument]) -> [Int] {
        sources.map { $0.pageCount }
    }

    /// Wrap an image file as a one-page PDFDocument so it can be added to the
    /// editor alongside PDFs. The page is sized to the image's pixel dimensions
    /// (points), keeping resolution and making the page size deterministic
    /// regardless of the file's DPI metadata.
    static func documentFromImage(url: URL) -> PDFDocument? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard let page = PDFPage(image: image) else { return nil }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return doc
    }

    /// Build a fresh PDFDocument from the given page refs. Each source page is
    /// **copied** (never inserted by reference — a PDFPage holds a back-pointer
    /// to its document, so sharing an instance across documents corrupts state)
    /// and its rotation is set to the source rotation plus the editor delta.
    ///
    /// Redacted pages: when `flattenRedactions` is true (export), each redacted
    /// page is rasterized with the black boxes baked in, so no text or vector
    /// content survives under them. When false (on-screen preview), redactions
    /// are drawn as cosmetic black annotations on the vector copy — reversible,
    /// and never written to disk.
    static func makeDocument(sources: [PDFDocument], refs: [PageRef],
                             flattenRedactions: Bool) -> PDFDocument {
        let out = PDFDocument()
        for ref in refs {
            guard sources.indices.contains(ref.docIndex),
                  let source = sources[ref.docIndex].page(at: ref.pageIndex) else { continue }

            if !ref.redactions.isEmpty, flattenRedactions {
                if let flat = flattenedPage(source: source, ref: ref) {
                    out.insert(flat, at: out.pageCount)
                }
                continue
            }

            guard let copy = source.copy() as? PDFPage else { continue }
            copy.rotation = PdfEditModel.normalizedRotation(source.rotation + ref.rotationDelta)
            if !ref.redactions.isEmpty { addPreviewAnnotations(ref.redactions, to: copy) }
            out.insert(copy, at: out.pageCount)
        }
        return out
    }

    /// Assemble the refs and write them to `url`, flattening every redacted
    /// page so hidden content cannot be recovered. Throws on an empty selection
    /// or a failed write.
    static func write(sources: [PDFDocument], refs: [PageRef], to url: URL) throws {
        let document = makeDocument(sources: sources, refs: refs, flattenRedactions: true)
        guard document.pageCount > 0 else { throw AssembleError.empty }
        guard document.write(to: url) else { throw AssembleError.writeFailed(url) }
    }

    /// Draw redactions as opaque black `.square` annotations. Preview-only: these
    /// sit on top of the still-present text/vector content, so they must never be
    /// exported — use the flatten path for that.
    static func addPreviewAnnotations(_ redactions: [RedactRect], to page: PDFPage) {
        for rect in redactions {
            let annotation = PDFAnnotation(
                bounds: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                forType: .square, withProperties: nil)
            annotation.color = .black
            annotation.interiorColor = .black
            annotation.border = PDFBorder()
            annotation.border?.lineWidth = 0
            page.addAnnotation(annotation)
        }
    }

    /// Rasterize a redacted page at 2x (144 DPI) with the black boxes baked in.
    /// The resulting page has no text layer and rotation 0 (rotation is baked
    /// into the pixels), while keeping the original point dimensions.
    static func flattenedPage(source: PDFPage, ref: PageRef) -> PDFPage? {
        let rotation = PdfEditModel.normalizedRotation(source.rotation + ref.rotationDelta)
        let media = source.bounds(for: .mediaBox)
        let displaySize = rotation % 180 == 0
            ? NSSize(width: media.width, height: media.height)
            : NSSize(width: media.height, height: media.width)
        let scale: CGFloat = 2

        let pixelWidth = Int((displaySize.width * scale).rounded())
        let pixelHeight = Int((displaySize.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Opaque white base — rasters have no transparency, and some PDFs draw
        // on an assumed white page.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.scaleBy(x: scale, y: scale)

        // Map unrotated page space → rotated display space (PDF /Rotate is
        // clockwise). After this the CTM is page space, so redaction rects and
        // the page content share one coordinate system.
        switch rotation {
        case 90:
            ctx.translateBy(x: 0, y: media.width)
            ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: media.width, y: media.height)
            ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: media.height, y: 0)
            ctx.rotate(by: .pi / 2)
        default:
            break
        }
        ctx.translateBy(x: -media.minX, y: -media.minY)

        // Draw the raw page with PDFKit's own rotation neutralized — our CTM
        // owns rotation, deterministically.
        if let copy = source.copy() as? PDFPage {
            copy.rotation = 0
            copy.draw(with: .mediaBox, to: ctx)
        }

        // Bake the black boxes in the same page-space CTM (no conversion).
        ctx.setFillColor(NSColor.black.cgColor)
        for rect in ref.redactions {
            ctx.fill(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        // Retina wrap: page media box = display points, backed by the 2x bitmap.
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = displaySize
        let image = NSImage(size: displaySize)
        image.addRepresentation(rep)
        return PDFPage(image: image)
    }

    /// Render a page thumbnail fitting within `maxSize`, preserving aspect.
    static func thumbnail(for page: PDFPage, maxSize: NSSize) -> NSImage {
        page.thumbnail(of: maxSize, for: .cropBox)
    }
}
