# Fixtures from supernote-typescript

These files are copied unchanged from [philips/supernote-typescript](https://github.com/philips/supernote-typescript/tree/1ba2d24b27d3209d021aa695d542f05ce5f7f971/tests/input) at commit `1ba2d24`, licensed under the Apache License 2.0 (see [LICENSE](LICENSE)). Upstream's [fixture notes](https://github.com/philips/supernote-typescript/blob/1ba2d24b27d3209d021aa695d542f05ce5f7f971/tests/input/README.md) say what each file was made to isolate, and its [format spec](https://github.com/philips/supernote-typescript/blob/1ba2d24b27d3209d021aa695d542f05ce5f7f971/plans/vector-format-spec.md) documents the stroke record layout. Several of the expected counts in `UpstreamFixtureTests` come from the device's own PDF exports described there.

They give us test coverage beyond the Manta: A5X, A6X (Nomad), N6, landscape pages and older format versions.

| File | Covers |
|---|---|
| `erase-n6-20230015-horizontal-1270.note` | N6 landscape page (1872×1404); stroke records with disable areas; 61 visible strokes, matching the device export |
| `sticker-n5-20260016-plugin-artwork.note` | Sticker plugin artwork (contour-only records); a page without TOTALPATH |
| `erase-n5-20260016-mixed-colors.note` | Grey and black ink erased side by side; records with epa data |
| `test-a5x-20220011-old-pen-ids.note` | Oldest format (`SN_FILE_VER_20220011`), LAYER1 content, old pen ids and palette colours |
| `heading-n5-20260016-backgrounds-marker.note` | Heading backgrounds, stored as text-box-like frames with the text "none" |
| `line-n5-20260016-ruler-tool.note` | Ruler / straight-line tool |
| `erase-n5-20260016-no-white-pen.note` | Every stroke erased, so no visible ink |
| `caligraphy-n5-20260016-widths-erase.note` | Calligraphy pen at three widths and colours, then erased |
| `stroke-n5-20260016-isolation-tools-colors-widths.note` | One pen, colour or width per stroke, including white ink |
| `layout-n5-20230015-horizontal-1090.note` | Manta landscape page (2560×1920) |
| `digest-n5-20230015-test.mark` | `.mark` without its companion PDF |
| `blank-a6x-3.26.40-two-pages.note` | A6X pages without TOTALPATH |
| `render-n6-20230015-moonchild-user-bg.note` | Custom user background image |
