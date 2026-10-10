# Supernote Viewer

Supernote files on macOS, the native way:

- **Double-click** a `.note` or `.pdf.mark` file and it opens in **Preview**. Handwriting is sharp vector at any zoom, and it is searchable and selectable through an invisible text layer from Apple's on-device recognizer (German + English).
- **Press Space** in Finder for a Quick Look preview.

- `.note`: every page, including the template background and highlighter layers.
- `X.pdf.mark`: the original `X.pdf` with your handwriting drawn on top. The PDF must sit next to the `.mark` file. If it's missing, the ink is shown on blank pages.

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

This installs `~/Applications/Supernote Viewer.app`, which carries the Quick Look extension. If previews don't show up, open the app once. Then check that "Supernote Quick Look" is enabled under System Settings → General → Login Items & Extensions → Quick Look.

## Layout

- `SupernoteKit/`: Swift package with the file parser, RLE decoder, layer compositor, stroke (`TOTALPATH`) parser, vector renderer, handwriting text layer and PDF renderer.
  - `swift test` runs the tests against `example_files/`.
  - `swift run -c release snrender <file> out.pdf [--png outdir] [--bitmap] [--ocr]` renders a file from the command line.
- `QuickLookPreview/`: the Quick Look extension. It is data-based and returns a PDF built by `PDFRenderer`.
- `App/`: the app. It declares the `.note` and `.mark` file types, renders opened files, and hands them to Preview.
- `project.yml`: the XcodeGen spec. The `.xcodeproj` is generated from it.

## Stroke data (`TOTALPATH`)

Each page's `TOTALPATH` block holds every stroke, including the device's own rendered outline polygons. Filling those outlines reproduces the device bitmap exactly. See `Strokes.swift` for the record layout.
- Erased strokes stay in the file, flagged −4.
- Surviving pieces of erased strokes are stored as outline-only fragments.
- Eraser strokes have color 255.

A per-layer coverage check falls back to the bitmap if the strokes don't account for the layer's ink.

Format notes come from [supernotelib](https://github.com/jya-dev/supernote-tool) and [GoSNare](https://github.com/alefaraci/GoSNare).
