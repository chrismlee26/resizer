# Resizer

A tiny macOS menu bar droplet for resizing photos and converting videos to
GIF or animated WebP, built on `sips` (built into macOS), `ffmpeg`
(Homebrew), and optionally `gifsicle` (Homebrew) for lossy GIF compression.

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
- `Sources/DropView.swift` / `AppDelegate.swift` — status item + drag & drop
- `Sources/OptionsWindowController.swift` — the options panel
- `Sources/VideoTrimView.swift` — inline video preview + trim controls for
  single-video drops
- `Sources/TrimRangeSlider.swift` — custom two-handle range slider (AppKit
  has no native one)
- `Sources/AboutWindowController.swift` — About window (version, changelog,
  link)
- `Resources/AppIcon.png` — app icon source; build.sh scales it into the .icns

App icon: [Resize](https://icons8.com/icons/set/resize) by [Icons8](https://icons8.com).
