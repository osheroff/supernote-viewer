# Supernote Viewer

Quick Look previews for Supernote files on macOS: select a file in Finder and press Space.

- `.note`: every page, including the template background and highlighter layers.
- `X.pdf.mark`: the original `X.pdf` with your handwriting drawn on top. The PDF must sit next to the `.mark` file. If it's missing, the ink is shown on blank pages.

Tested with Supernote Manta files (format `SN_FILE_VER_20260016`, Chauvet 3.28.42).

## Build and install

```sh
brew install xcodegen   # once
./install.sh
```

This installs `~/Applications/Supernote Viewer.app`, which carries the Quick Look extension. If previews don't show up, open the app once. Then check that "Supernote Quick Look" is enabled under System Settings → General → Login Items & Extensions → Quick Look.

## Layout

- `SupernoteKit/`: Swift package with the file parser, RLE decoder, layer compositor and PDF renderer.
  - `swift test` runs the tests against `example_files/`.
  - `swift run -c release snrender <file> out.pdf --png outdir` renders a file from the command line.
- `QuickLookPreview/`: the Quick Look extension. It is data-based and returns a PDF built by `PDFRenderer`.
- `App/`: the minimal host app. It declares the `.note` and `.mark` file types.
- `project.yml`: the XcodeGen spec. The `.xcodeproj` is generated from it.

Format notes come from [supernotelib](https://github.com/jya-dev/supernote-tool) and [GoSNare](https://github.com/alefaraci/GoSNare).
