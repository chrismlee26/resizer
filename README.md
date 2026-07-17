# Resizer

A tiny macOS menu bar droplet for resizing photos and converting videos to
GIFs, built on `sips` (built into macOS) and `ffmpeg` (Homebrew).

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
- **Videos → GIF** — set width, FPS, and palette colors (fewer colors =
  smaller file). Optionally set **Max MB**: Resizer re-encodes at smaller
  widths until the GIF fits under that size — handy for Slack/email limits.

You can also drop files onto the app icon in Finder, use "Open With →
Resizer", or pick **Open Files…** from the menu bar menu.

## Build & install

```bash
./build.sh            # builds build/Resizer.app
./build.sh install    # builds and copies to /Applications
```

Requires Xcode command line tools (`swiftc`) and `ffmpeg`
(`brew install ffmpeg`). Image resizing works without ffmpeg.

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
- `Sources/GifProcessor.swift` — ffmpeg two-pass palette GIF encode with
  optional target-size retry loop
- `Sources/DropView.swift` / `AppDelegate.swift` — status item + drag & drop
- `Sources/OptionsWindowController.swift` — the options panel
- `Resources/AppIcon.png` — app icon source; build.sh scales it into the .icns

App icon: [Resize](https://icons8.com/icons/set/resize) by [Icons8](https://icons8.com).
