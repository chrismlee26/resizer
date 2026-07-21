import Foundation

// Minimal assertion harness (no XCTest — this compiles with plain swiftc).
var failures = 0
func expect(_ condition: Bool, _ message: String,
            file: String = #file, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL [\(URL(fileURLWithPath: file).lastPathComponent):\(line)] \(message)")
    }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String,
                               file: String = #file, line: Int = #line) {
    expect(a == b, "\(message) — got \(a), expected \(b)", file: file, line: line)
}

// Convenience: describe a model's page list as (doc, page, rotation) triples.
func triples(_ m: PdfEditModel) -> [[Int]] {
    m.pages.map { [$0.docIndex, $0.pageIndex, $0.rotationDelta] }
}

// normalizedRotation
expectEqual(PdfEditModel.normalizedRotation(0), 0, "0 stays 0")
expectEqual(PdfEditModel.normalizedRotation(90), 90, "90 stays 90")
expectEqual(PdfEditModel.normalizedRotation(360), 0, "360 wraps to 0")
expectEqual(PdfEditModel.normalizedRotation(270 + 90), 0, "270+90 wraps to 0")
expectEqual(PdfEditModel.normalizedRotation(-90), 270, "-90 normalizes to 270")
expectEqual(PdfEditModel.normalizedRotation(-450), 270, "-450 normalizes to 270")

// init: concatenation in drop order (combine)
let combined = PdfEditModel(pageCounts: [3, 2])
expectEqual(combined.count, 5, "3+2 pages combine to 5")
expectEqual(triples(combined),
            [[0, 0, 0], [0, 1, 0], [0, 2, 0], [1, 0, 0], [1, 1, 0]],
            "pages concatenate doc0 then doc1, in page order")
expectEqual(PdfEditModel(pageCounts: [0, 2]).count, 2, "empty doc contributes nothing")

// rotate
var rot = PdfEditModel(pageCounts: [3])
rot.rotate([0, 2], by: 90)
expectEqual(triples(rot), [[0, 0, 90], [0, 1, 0], [0, 2, 90]], "rotate selection by 90")
rot.rotate([0], by: 90)
expectEqual(rot.pages[0].rotationDelta, 180, "second rotate accumulates to 180")
rot.rotate([2], by: -90)
expectEqual(rot.pages[2].rotationDelta, 0, "90 then -90 returns to 0")
var rotWrap = PdfEditModel(pageCounts: [1])
rotWrap.rotate([0], by: 270)
rotWrap.rotate([0], by: 90)
expectEqual(rotWrap.pages[0].rotationDelta, 0, "270+90 wraps to 0")

// delete: index math + next selection
var del = PdfEditModel(pageCounts: [5])
let nextSel = del.delete([1, 3])
expectEqual(triples(del), [[0, 0, 0], [0, 2, 0], [0, 4, 0]], "delete removes correct pages")
expectEqual(nextSel, 1, "next selection is the slot the first deleted page vacated")
var delEnd = PdfEditModel(pageCounts: [3])
expectEqual(delEnd.delete([2]), 1, "deleting last page selects new last page")
var delAll = PdfEditModel(pageCounts: [2])
expectEqual(delAll.delete([0, 1]), 0, "delete-all returns 0")
expect(delAll.isEmpty, "delete-all empties the list")

// move: multi-select reorder with destination past removed items
var mv = PdfEditModel(pageCounts: [6])   // pages 0..5
let moved = mv.move([0, 1], to: 4)       // move first two to before old index 4
expectEqual(mv.pages.map { $0.pageIndex }, [2, 3, 0, 1, 4, 5],
            "moved pages land before old index 4, relative order kept")
expectEqual(moved, [2, 3], "returns new indices of the moved pages")
// move backward
var mvBack = PdfEditModel(pageCounts: [5])
let movedBack = mvBack.move([3, 4], to: 1)
expectEqual(mvBack.pages.map { $0.pageIndex }, [0, 3, 4, 1, 2],
            "moving later pages earlier inserts at the drop point")
expectEqual(movedBack, [1, 2], "backward move new indices")
// no-op move does not dirty the model
var mvNoop = PdfEditModel(pageCounts: [3])
_ = mvNoop.move([1], to: 1)
expect(!mvNoop.isDirty, "moving a page to its own position is a no-op")
_ = mvNoop.move([1], to: 2)
expect(!mvNoop.isDirty, "moving to the slot right after itself is a no-op")

// moveToIndex: type a new page number
var num = PdfEditModel(pageCounts: [5])          // pages 0..4
let landed = num.moveToIndex(4, to: 0)           // page 5 → position 1
expectEqual(landed, 0, "moveToIndex returns the final position")
expectEqual(num.pages.map { $0.pageIndex }, [4, 0, 1, 2, 3],
            "moving the last page to index 0 pushes the rest down")
var numDown = PdfEditModel(pageCounts: [5])
let landedDown = numDown.moveToIndex(0, to: 4)   // page 1 → last
expectEqual(numDown.pages.map { $0.pageIndex }, [1, 2, 3, 4, 0],
            "moving the first page to the last index shifts the rest up")
expectEqual(landedDown, 4, "moving down lands at the target index")
var numMid = PdfEditModel(pageCounts: [6])
_ = numMid.moveToIndex(1, to: 4)
expectEqual(numMid.pages.map { $0.pageIndex }, [0, 2, 3, 4, 1, 5],
            "mid-list move places the page at the exact target index")
var numNoop = PdfEditModel(pageCounts: [3])
_ = numNoop.moveToIndex(1, to: 1)
expect(!numNoop.isDirty && !numNoop.canUndo, "moving a page to its own index is a no-op")
var numClamp = PdfEditModel(pageCounts: [3])
let clamped = numClamp.moveToIndex(0, to: 99)
expectEqual(clamped, 2, "out-of-range target clamps to the last index")
var numUndo = PdfEditModel(pageCounts: [4])
_ = numUndo.moveToIndex(3, to: 0)
expect(numUndo.undo(), "moveToIndex is undoable")
expectEqual(numUndo.pages.map { $0.pageIndex }, [0, 1, 2, 3], "undo restores original order")

// refs (extract): page order, not selection-click order
let ex = PdfEditModel(pageCounts: [4])
let refs = ex.refs(at: [3, 0, 2])
expectEqual(refs.map { $0.pageIndex }, [0, 2, 3], "extract refs are in page order")

// undo / revert / isDirty
var hist = PdfEditModel(pageCounts: [3])
expect(!hist.isDirty, "fresh model is not dirty")
expect(!hist.canUndo, "fresh model has nothing to undo")
hist.rotate([0], by: 90)
hist.delete([2])
expect(hist.isDirty, "edits make the model dirty")
expect(hist.undo(), "undo returns true when history exists")
expectEqual(hist.count, 3, "undo restores the deleted page")
expect(hist.undo(), "second undo")
expect(!hist.isDirty, "undoing all edits clears dirty")
expect(!hist.undo(), "undo with empty history returns false")

var rev = PdfEditModel(pageCounts: [3])
rev.rotate([0], by: 90)
rev.move([2], to: 0)
rev.revert()
expectEqual(triples(rev), [[0, 0, 0], [0, 1, 0], [0, 2, 0]], "revert restores original list")
expect(!rev.isDirty, "revert clears dirty")
expect(rev.undo(), "revert itself is undoable")
expect(rev.isDirty, "undoing a revert brings edits back")

// appendPages: adds new documents' pages to the bottom
var app = PdfEditModel(pageCounts: [3])
let firstNew = app.appendPages(startDocIndex: 1, pageCounts: [2])
expectEqual(firstNew, 3, "first appended page is at the old count")
expectEqual(app.count, 5, "append grows the page list")
expectEqual(triples(app),
            [[0, 0, 0], [0, 1, 0], [0, 2, 0], [1, 0, 0], [1, 1, 0]],
            "appended pages carry the new doc index and land at the bottom")
expect(app.isDirty, "appending dirties the model")
expect(app.undo(), "append is undoable")
expectEqual(app.count, 3, "undo removes the appended pages")
var appEmpty = PdfEditModel(pageCounts: [2])
_ = appEmpty.appendPages(startDocIndex: 1, pageCounts: [0])
expect(!appEmpty.isDirty && !appEmpty.canUndo, "appending an empty document is a no-op")
var appMany = PdfEditModel(pageCounts: [1])
_ = appMany.appendPages(startDocIndex: 1, pageCounts: [1, 2])
expectEqual(triples(appMany),
            [[0, 0, 0], [1, 0, 0], [2, 0, 0], [2, 1, 0]],
            "appending multiple docs indexes each correctly")

// redaction: storage + guards
var red = PdfEditModel(pageCounts: [3])
red.addRedaction(RedactRect(x: 10, y: 20, width: 100, height: 40), at: 1)
expectEqual(red.pages[1].redactions.count, 1, "redaction is stored on the page")
expect(red.hasRedactions(at: 1), "hasRedactions reports the redacted page")
expect(!red.hasRedactions(at: 0), "clean page reports no redactions")
expectEqual(red.redactedPageCount, 1, "one page carries a redaction")
expect(red.isDirty, "adding a redaction dirties the model")

var redGuard = PdfEditModel(pageCounts: [2])
redGuard.addRedaction(RedactRect(x: 0, y: 0, width: 0, height: 40), at: 0)
expect(!redGuard.isDirty && !redGuard.canUndo, "zero-size redaction is a no-op")
redGuard.addRedaction(RedactRect(x: 0, y: 0, width: 10, height: 10), at: 9)
expect(!redGuard.isDirty && !redGuard.canUndo, "out-of-range redaction is a no-op")

// redaction: undo / clear / revert
var redHist = PdfEditModel(pageCounts: [2])
redHist.addRedaction(RedactRect(x: 1, y: 1, width: 5, height: 5), at: 0)
redHist.addRedaction(RedactRect(x: 2, y: 2, width: 6, height: 6), at: 0)
expectEqual(redHist.pages[0].redactions.count, 2, "two redactions on one page")
expect(redHist.undo(), "undo pops the last redaction")
expectEqual(redHist.pages[0].redactions.count, 1, "undo leaves the first redaction")
redHist.clearRedactions(at: [0])
expect(redHist.pages[0].redactions.isEmpty, "clearRedactions empties the page")
var redClean = PdfEditModel(pageCounts: [2])
redClean.clearRedactions(at: [0, 1])
expect(!redClean.isDirty && !redClean.canUndo, "clearRedactions on clean pages is a no-op")
var redRevert = PdfEditModel(pageCounts: [1])
redRevert.addRedaction(RedactRect(x: 3, y: 3, width: 9, height: 9), at: 0)
redRevert.revert()
expect(redRevert.pages[0].redactions.isEmpty, "revert clears redactions")

// redaction: rides along through reorder + delete
var redMove = PdfEditModel(pageCounts: [4])
redMove.addRedaction(RedactRect(x: 7, y: 7, width: 20, height: 20), at: 2)
redMove.move([2], to: 0)
expect(redMove.hasRedactions(at: 0), "redaction follows its page after move")
expect(!redMove.hasRedactions(at: 2), "old position no longer redacted after move")
var redDelete = PdfEditModel(pageCounts: [4])
redDelete.addRedaction(RedactRect(x: 7, y: 7, width: 20, height: 20), at: 3)
redDelete.delete([0])
expect(redDelete.hasRedactions(at: 2), "redaction stays attached to its page after delete shifts indices")

// redaction: Equatable distinguishes redaction state
var redA = PdfEditModel(pageCounts: [1])
let redB = PdfEditModel(pageCounts: [1])
redA.addRedaction(RedactRect(x: 0, y: 0, width: 1, height: 1), at: 0)
expect(redA != redB, "models differing only in redactions are unequal")

if failures > 0 {
    print("\(failures) pdf model test(s) failed")
    exit(1)
}
print("All pdf model tests passed")
