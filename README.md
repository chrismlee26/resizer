# Resizer

A tiny macOS menu bar droplet for resizing photos, converting videos to GIF
or animated WebP, and editing PDFs — built on `sips` (built into macOS),
`ffmpeg` (Homebrew), optionally `gifsicle` (Homebrew) for lossy GIF
compression, and Apple's PDFKit (no external tool) for PDFs.

One droplet, two apps: Resizer detects what you drop and routes it. Images
and videos open the resize/convert options panel; PDFs open the PDF editor.
A mixed drop opens both. Everything runs locally.

## Usage

Drag photos or videos onto the **⤢ icon in the menu bar**. An options panel
appears:

- **Images** — scale by percent, fit within a box, or exact dimensions. The
  original resolution is always shown in the panel. "Scale by percent"
  shows a live "→ W × H px" readout of the final size. "Exact dimensions"
  opens pre-filled with the original resolution, keeps width/height locked
  to the original aspect ratio, and has a 1–100% scale slider. Output lands
  next to the original as
  `name-<width>w-<random>.ext`; originals and existing files are never
  replaced. Switch **Output** to "Ask for name…" to pick each output name in
  a save panel instead.
- **Videos → GIF / WebP** — pick an output **Format** (GIF or animated
  WebP), width, FPS (preset dropdown, 15 recommended), and for GIF the
  palette colors (fewer colors = smaller file). The panel shows the
  original video's file size, resolution, and duration, plus a live
  **estimated output size** that updates as you change settings (rough —
  expect real results within ~2× either way). WebP is typically several
  times smaller than GIF at the same resolution; use GIF only where the
  consumer requires it (e.g. GitHub READMEs).
  - **Compression** — None / Balanced (recommended) / Strong. For GIF this
    runs a `gifsicle -O3 --lossy` pass (30/80); Strong saves ~35% but can
    ghost on fast motion. For WebP it maps to quality q90/q75/q50. GIF
    compression needs `gifsicle` (`brew install gifsicle`) — without it,
    the dropdown defaults to None and conversion still works.
  - **Max MB** — Resizer re-encodes at smaller widths until the output
    fits under that size — handy for Slack/email limits.
  - **Trim** — single-video drops show an inline muted preview with a
    two-handle range slider. Dragging a handle seeks the preview to that
    frame, Play replays exactly the selected range, and the size estimate
    tracks the shortened clip. Leave the handles at the ends to export the
    full video.

Drop one or more **PDFs** instead and the **PDF editor** opens:

- **Combine** — dropping several PDFs concatenates them into one working
  document, in drop order.
- **Add PDF/Image** — the toolbar button opens more PDFs or images while you
  work; their pages are appended to the bottom of the list (each image becomes
  a one-page document). Undoable like any other edit.
- **Thumbnails + preview** — a scrollable page-thumbnail sidebar sits beside
  a full-page preview. Selecting a thumbnail scrolls the preview to it, and
  scrolling the preview highlights the matching thumbnail, so you can verify
  you're on the right page and see the reassembled document as you go.
- **Rotate / Delete / Extract** — act on one page or a multi-selection.
  Rotate turns the selected pages ±90° (a badge shows the applied rotation);
  Delete removes them; **Extract…** saves the selected pages as a new PDF via
  a save panel, leaving the working document untouched.
- **Reorder** — drag thumbnails to change page order; dragging to the top or
  bottom edge of the sidebar auto-scrolls, so you can move a page any distance.
  Each thumbnail also has an editable page-number field — type a new number
  (e.g. change 13 to 1) and confirm with Return or the ✓ button beside the
  field, and the page jumps to that position, pushing the rest down.
- **Redact** — toggle **Redact** and drag black boxes over anything sensitive
  (draw as many as you like; Esc or toggling off exits). On **Export/Extract**,
  any page carrying a redaction is flattened to a 144-DPI image with the boxes
  baked in, so the text and vector content underneath is **gone — not just
  hidden** (it cannot be selected, copied, or recovered). Pages without
  redactions stay as vector, so flattening only happens where needed. Use
  **Clear Redactions** to remove the boxes on the selected pages; ⌘Z / Revert
  work too. The on-screen boxes before export are a reversible preview; only
  the exported file is flattened.
- **Undo / Revert** — ⌘Z (or the Undo button) steps back through edits;
  Revert returns to the pages as originally dropped.
- **Export…** — writes the reassembled document to a filename you choose
  (defaults to `name-edited-<random>.pdf`). The export is built fresh from
  the original files, so source PDFs are never modified, and Resizer refuses
  a name that would overwrite a source.

Password-protected PDFs prompt for the password on open; encrypted or
unreadable files in a multi-drop are skipped with a note. PDF editing is
page-level, so interactive form fields, outlines, and internal links are not
carried into the exported document.

You can also drop files onto the app icon in Finder, use "Open With →
Resizer", or pick **Load File…** from the menu bar menu. **About Resizer**
in the same menu shows the version, build number, and a changelog generated
from git history at build time.

## Build & install

```bash
./build.sh            # builds build/Resizer.app
./build.sh install    # builds and copies to /Applications
```

When building inside a git clone, `build.sh` stamps the build number
(`CFBundleVersion`) with the git commit count and generates the About
window's changelog from `git log`; outside a clone both steps are skipped.

Requires Xcode command line tools (`swiftc`) and `ffmpeg`
(`brew install ffmpeg`). Image resizing works without ffmpeg. Lossy GIF
compression additionally uses `gifsicle` (`brew install gifsicle`).

To launch at login: System Settings → General → Login Items → add Resizer.

## Tests

```bash
tests/run_tests.sh    # unit tests (sizing math) + integration (real sips/ffmpeg runs)
```

## Layout

- `Sources/Geometry.swift` — pure sizing math (percent/fit/exact/max-width,
  GIF shrink-to-target stepping, collision-free output naming)
- `Sources/ToolRunner.swift` — Process wrapper + Homebrew-aware binary lookup
- `Sources/ImageProcessor.swift` — sips pipeline (copy, then resample the copy)
- `Sources/GifProcessor.swift` — ffmpeg two-pass palette GIF encode
  (inter-frame optimized) with optional gifsicle lossy pass, animated WebP
  encode, output size estimator, and target-size retry loop
- `Sources/VideoProbe.swift` — AVFoundation metadata loader (resolution,
  duration, file size) behind the panel's original/estimate labels
- `Sources/DropView.swift` / `AppDelegate.swift` — status item + drag & drop;
  classifies each file as image / video / PDF and routes it
- `Sources/OptionsWindowController.swift` — the options panel
- `Sources/VideoTrimView.swift` — inline video preview + trim controls for
  single-video drops
- `Sources/TrimRangeSlider.swift` — custom two-handle range slider (AppKit
  has no native one)
- `Sources/PdfEditModel.swift` — pure page-list editing logic (combine,
  reorder, rotate, delete, extract refs, undo/revert), fully unit-tested
- `Sources/PdfAssembler.swift` — PDFKit plumbing: load, copy pages, assemble
  a fresh document, thumbnails, and secure flatten-on-export of redacted pages
- `Sources/PdfRedactOverlayView.swift` — transparent capture layer for drawing
  redaction boxes over the preview (view→page coordinate conversion)
- `Sources/PdfThumbnailListView.swift` — NSCollectionView thumbnail sidebar
  with multi-select, drag-reorder, and lazy off-main thumbnail rendering
- `Sources/PdfEditorWindowController.swift` — the PDF editor window
  (sidebar + PDFView preview, toolbar operations, export/extract)
- `Sources/AboutWindowController.swift` — About window (version, changelog,
  link)
- `Resources/AppIcon.png` — app icon source; build.sh scales it into the .icns

App icon: [Resize](https://icons8.com/icons/set/resize) by [Icons8](https://icons8.com).
