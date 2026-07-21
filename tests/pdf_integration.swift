import Foundation
import PDFKit

// End-to-end check of the PDFKit assembly pipeline. Generates its own PDF
// fixtures in-process (pages with distinct widths so page identity survives a
// write/reopen round-trip and can be asserted by media-box width). Expects a
// writable working directory as argv[1]. No ffmpeg dependency.

let workDir = URL(fileURLWithPath: CommandLine.arguments[1])
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
    else { print("ok: \(message)") }
}

// MARK: - Fixture helpers

func makeImage(width: Int, height: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    return image
}

/// A PDF whose pages have the given widths (height fixed at 200). Optionally
/// pre-rotates a page to exercise source-rotation handling.
func makeFixture(widths: [Int], rotate: [Int: Int] = [:]) -> PDFDocument {
    let doc = PDFDocument()
    for (i, width) in widths.enumerated() {
        guard let page = PDFPage(image: makeImage(width: width, height: 200)) else {
            fatalError("could not build fixture page")
        }
        if let r = rotate[i] { page.rotation = r }
        doc.insert(page, at: i)
    }
    return doc
}

func widths(of doc: PDFDocument) -> [Int] {
    (0..<doc.pageCount).map { Int(doc.page(at: $0)!.bounds(for: .mediaBox).width.rounded()) }
}

func reopen(_ url: URL) -> PDFDocument { PDFDocument(url: url)! }

/// A one-page PDF with real, selectable text (unlike the image fixtures, whose
/// pages have an empty `string`). NSTextField renders a genuine text layer.
func makeTextPDF(_ text: String, size: NSSize) -> PDFDocument {
    let field = NSTextField(labelWithString: text)
    field.frame = NSRect(origin: .zero, size: size)
    return PDFDocument(data: field.dataWithPDF(inside: field.bounds))!
}

// MARK: - Write fixtures to disk

let doc0URL = workDir.appendingPathComponent("fixture0.pdf")
let doc1URL = workDir.appendingPathComponent("fixture1.pdf")
_ = makeFixture(widths: [101, 102, 103]).write(to: doc0URL)
_ = makeFixture(widths: [111, 112]).write(to: doc1URL)
let doc0Bytes = try FileManager.default.attributesOfItem(atPath: doc0URL.path)[.size] as! Int
let doc1Bytes = try FileManager.default.attributesOfItem(atPath: doc1URL.path)[.size] as! Int

func loadSources() -> [PDFDocument] {
    [reopen(doc0URL), reopen(doc1URL)]
}

// MARK: - Combine (concatenate in drop order)

do {
    let sources = loadSources()
    let model = PdfEditModel(pageCounts: PdfAssembler.pageCounts(of: sources))
    let out = workDir.appendingPathComponent("combined.pdf")
    try PdfAssembler.write(sources: sources, refs: model.pages, to: out)
    expect(widths(of: reopen(out)) == [101, 102, 103, 111, 112],
           "combine concatenates both docs in page order")
}

// MARK: - Reorder + delete + rotate

do {
    let sources = loadSources()
    var model = PdfEditModel(pageCounts: PdfAssembler.pageCounts(of: sources))
    model.move([0], to: 5)       // 101 → end: [102,103,111,112,101]
    model.delete([1])            // remove 103: [102,111,112,101]
    model.rotate([0], by: 90)    // rotate the 102 page
    let out = workDir.appendingPathComponent("edited.pdf")
    try PdfAssembler.write(sources: sources, refs: model.pages, to: out)
    let result = reopen(out)
    expect(widths(of: result) == [102, 111, 112, 101],
           "reorder+delete produce the expected page order")
    expect(result.page(at: 0)!.rotation == 90, "rotated page carries 90° after round-trip")
    expect(result.page(at: 1)!.rotation == 0, "untouched page keeps 0° rotation")
}

// MARK: - Source rotation composes with the editor delta

do {
    let rotURL = workDir.appendingPathComponent("prerotated.pdf")
    _ = makeFixture(widths: [120], rotate: [0: 90]).write(to: rotURL)
    let sources = [reopen(rotURL)]
    var model = PdfEditModel(pageCounts: PdfAssembler.pageCounts(of: sources))
    model.rotate([0], by: 90)    // 90 (source) + 90 (delta) = 180
    let out = workDir.appendingPathComponent("prerotated-out.pdf")
    try PdfAssembler.write(sources: sources, refs: model.pages, to: out)
    expect(reopen(out).page(at: 0)!.rotation == 180,
           "source rotation composes with editor delta")
}

// MARK: - Extract selected pages (page order, not click order)

do {
    let sources = loadSources()
    let model = PdfEditModel(pageCounts: PdfAssembler.pageCounts(of: sources))
    let out = workDir.appendingPathComponent("extracted.pdf")
    try PdfAssembler.write(sources: sources, refs: model.refs(at: [4, 0, 2]), to: out)
    expect(widths(of: reopen(out)) == [101, 103, 112],
           "extract writes the selected pages in page order")
}

// MARK: - Originals never modified

do {
    let after0 = try FileManager.default.attributesOfItem(atPath: doc0URL.path)[.size] as! Int
    let after1 = try FileManager.default.attributesOfItem(atPath: doc1URL.path)[.size] as! Int
    expect(after0 == doc0Bytes && after1 == doc1Bytes, "source PDFs are byte-unchanged")
}

// MARK: - Empty selection is rejected

do {
    let sources = loadSources()
    let out = workDir.appendingPathComponent("empty.pdf")
    var threw = false
    do { try PdfAssembler.write(sources: sources, refs: [], to: out) }
    catch { threw = true }
    expect(threw, "writing an empty page list throws")
}

// MARK: - Encrypted document load outcome

do {
    let encURL = workDir.appendingPathComponent("encrypted.pdf")
    let opts: [PDFDocumentWriteOption: Any] = [
        .userPasswordOption: "secret",
        .ownerPasswordOption: "secret",
    ]
    _ = makeFixture(widths: [130]).write(to: encURL, withOptions: opts)

    switch PdfAssembler.load(url: encURL) {
    case .locked(let doc):
        expect(doc.isLocked, "encrypted fixture loads as locked")
        expect(!doc.unlock(withPassword: "wrong"), "wrong password does not unlock")
        expect(doc.unlock(withPassword: "secret"), "correct password unlocks")
    case .ok:
        expect(false, "encrypted fixture should not load as ok")
    case .unreadable:
        expect(false, "encrypted fixture should be readable-but-locked")
    }
}

// MARK: - Redaction: fixture has real, extractable text

let secret = "SECRET-PASSWORD-42"
let textURL = workDir.appendingPathComponent("secret.pdf")
_ = makeTextPDF(secret, size: NSSize(width: 400, height: 120)).write(to: textURL)
do {
    let page = reopen(textURL).page(at: 0)!
    expect((page.string ?? "").contains(secret),
           "text fixture exposes selectable text before redaction")
}

// MARK: - Secure redaction round-trip (flattened page loses its text layer)

do {
    // Two-doc set: the text page + a vector image page, so we can prove the
    // unredacted sibling keeps its vector content.
    let imgURL = workDir.appendingPathComponent("sibling.pdf")
    _ = makeFixture(widths: [155]).write(to: imgURL)
    let sources = [reopen(textURL), reopen(imgURL)]
    var model = PdfEditModel(pageCounts: PdfAssembler.pageCounts(of: sources))
    let media = sources[0].page(at: 0)!.bounds(for: .mediaBox)
    // Cover the whole text page.
    model.addRedaction(RedactRect(x: 0, y: 0, width: media.width, height: media.height), at: 0)

    let out = workDir.appendingPathComponent("redacted.pdf")
    try PdfAssembler.write(sources: sources, refs: model.pages, to: out)
    let result = reopen(out)
    expect(result.pageCount == 2, "page count preserved after redaction")
    let redacted = result.page(at: 0)!
    expect((redacted.string ?? "").isEmpty, "redacted page has no extractable text")
    expect(!(redacted.string ?? "").contains(secret), "the secret is not recoverable")
    expect(redacted.rotation == 0, "flattened page has rotation 0")
    expect(abs(redacted.bounds(for: .mediaBox).width - media.width) <= 1,
           "flattened page keeps its point width")
    expect(Int(result.page(at: 1)!.bounds(for: .mediaBox).width.rounded()) == 155,
           "unredacted sibling stays vector, dimensions intact")
}

// MARK: - Selective flattening (only redacted pages lose their text)

do {
    let aURL = workDir.appendingPathComponent("t-a.pdf")
    let bURL = workDir.appendingPathComponent("t-b.pdf")
    let cURL = workDir.appendingPathComponent("t-c.pdf")
    _ = makeTextPDF("ALPHA-KEEP", size: NSSize(width: 300, height: 100)).write(to: aURL)
    _ = makeTextPDF("BRAVO-HIDE", size: NSSize(width: 300, height: 100)).write(to: bURL)
    _ = makeTextPDF("CHARLIE-KEEP", size: NSSize(width: 300, height: 100)).write(to: cURL)
    let sources = [reopen(aURL), reopen(bURL), reopen(cURL)]
    var model = PdfEditModel(pageCounts: PdfAssembler.pageCounts(of: sources))
    model.addRedaction(RedactRect(x: 0, y: 0, width: 300, height: 100), at: 1)

    let out = workDir.appendingPathComponent("selective.pdf")
    try PdfAssembler.write(sources: sources, refs: model.pages, to: out)
    let result = reopen(out)
    expect((result.page(at: 0)!.string ?? "").contains("ALPHA-KEEP"),
           "page before the redaction keeps its text")
    expect((result.page(at: 1)!.string ?? "").isEmpty, "redacted middle page loses its text")
    expect((result.page(at: 2)!.string ?? "").contains("CHARLIE-KEEP"),
           "page after the redaction keeps its text")
}

// MARK: - Rotation composes with redaction (rotate then redact)

do {
    let sources = [reopen(textURL)]
    var model = PdfEditModel(pageCounts: PdfAssembler.pageCounts(of: sources))
    let media = sources[0].page(at: 0)!.bounds(for: .mediaBox)   // 400 × 120
    model.rotate([0], by: 90)
    model.addRedaction(RedactRect(x: 0, y: 0, width: media.width, height: media.height), at: 0)

    let out = workDir.appendingPathComponent("rotated-redacted.pdf")
    try PdfAssembler.write(sources: sources, refs: model.pages, to: out)
    let result = reopen(out).page(at: 0)!
    expect(result.rotation == 0, "flattened rotated page bakes rotation to 0")
    expect((result.string ?? "").isEmpty, "rotated + redacted page has no text")
    let bounds = result.bounds(for: .mediaBox)
    expect(abs(bounds.width - media.height) <= 1 && abs(bounds.height - media.width) <= 1,
           "90° rotation swaps the flattened page dimensions")
}

// MARK: - Preview is non-destructive; only export is secure

do {
    let sources = [reopen(textURL)]
    var model = PdfEditModel(pageCounts: PdfAssembler.pageCounts(of: sources))
    model.addRedaction(RedactRect(x: 0, y: 0, width: 50, height: 50), at: 0)

    let preview = PdfAssembler.makeDocument(sources: sources, refs: model.pages,
                                            flattenRedactions: false)
    expect((preview.page(at: 0)!.string ?? "").contains(secret),
           "preview keeps the text (annotation is cosmetic)")
    expect(preview.page(at: 0)!.annotations.count == 1, "preview carries one redaction annotation")

    let exported = PdfAssembler.makeDocument(sources: sources, refs: model.pages,
                                             flattenRedactions: true)
    expect((exported.page(at: 0)!.string ?? "").isEmpty, "export drops the text layer")
}

if failures > 0 {
    print("\(failures) pdf integration test(s) failed")
    exit(1)
}
print("All pdf integration tests passed")
