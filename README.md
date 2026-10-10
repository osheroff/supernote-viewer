# Supernote Viewer & Supernote Preview Bridge

Two macOS apps for Supernote files. Pick which one opens `.note` and `.pdf.mark` on double-click by changing the default app: in Finder, select a file → Get Info → Open with → choose the app → Change All… (once for a `.note`, once for a `.mark`).

- **Supernote Preview Bridge** renders the file to a PDF and opens it in **Preview**. Handwriting is sharp vector at any zoom, and it is searchable and selectable through an invisible text layer from Apple's on-device recognizer (German + English).
- **Supernote Viewer** opens the file in its own window:
  - **Thumbnails sidebar** (⌥⌘2).
  - **Live reload:** the window updates by itself when your Supernote syncs a change.
  - **Measuring:**
    1. Choose **Calibrate** and drag along a known length, then type it in (e.g. `2,23 m`).
    2. Choose **Measure** and drag to measure; hold ⇧ for straight lines; click a line and press ⌫ to delete it.
    3. Use **Export PDF…** to save the measurements as standard PDF annotations.

    Calibrations and measurements are remembered per file.
  - It also opens plain PDFs (Open With → Supernote Viewer) and provides the Finder action **"Measure in Supernote Viewer"** for `.note`, `.mark` and `.pdf`.
- **Quick Look:** press Space in Finder for a preview, whichever app is the default.

Preview opens a generated copy from `~/Library/Caches/dev.schaefer.SupernoteViewer/`.
- The copy is regenerated when the notebook changes.
- A copy you saved changes to in Preview is never overwritten; the next render goes to `Name 2.pdf`.
- To keep an annotated version, use File → Export or Duplicate.

Handwriting recognition is only as good as Apple Vision's on quick handwriting, so expect some misread words.

Tested with Supernote Manta files (format `SN_FILE_VER_20260016`, Chauvet 3.28.42).

## Build and install

```sh
brew install xcodegen   # once
./install.sh
```

This installs both apps to `~/Applications`. Supernote Viewer carries the Quick Look extension. If previews don't show up, open Supernote Viewer once. Then check that "Supernote Quick Look" is enabled under System Settings → General → Login Items & Extensions → Quick Look.

## Layout

- `SupernoteKit/`: Swift package with the file parser, RLE decoder, layer compositor, stroke (`TOTALPATH`) parser, vector renderer, handwriting text layer and PDF renderer.
  - `swift test` runs the tests against `example_files/`.
  - `swift run -c release snrender <file> out.pdf [--png outdir] [--bitmap] [--ocr]` renders a file from the command line.
- `QuickLookPreview/`: the Quick Look extension. It is data-based and returns a PDF built by `PDFRenderer`.
- `Shared/`: the render cache used by both apps (`~/Library/Caches/dev.schaefer.SupernoteViewer/`).
- `Viewer/`: Supernote Viewer.
  - Its PDFKit window has thumbnails, live reload and measuring.
  - It exports the `.note` and `.mark` file types.
- `Bridge/`: Supernote Preview Bridge.
  - It hands rendered PDFs to Preview.
  - It imports the file types, so it works on its own.
- `project.yml`: the XcodeGen spec. The `.xcodeproj` is generated from it.

## Stroke data (`TOTALPATH`)

Each page's `TOTALPATH` block holds every stroke, including the device's own rendered outline polygons. Filling those outlines reproduces the device bitmap exactly. See `Strokes.swift` for the record layout.
- Erased strokes stay in the file, flagged −4.
- Surviving pieces of erased strokes are stored as outline-only fragments.
- Eraser strokes have color 255.

A per-layer coverage check falls back to the bitmap if the strokes don't account for the layer's ink.

Format notes come from [supernotelib](https://github.com/jya-dev/supernote-tool) and [GoSNare](https://github.com/alefaraci/GoSNare).
