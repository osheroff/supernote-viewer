import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import SupernoteKit

final class SupernoteKitTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let examples = repo.appendingPathComponent("example_files")
    let noteURL = examples.appendingPathComponent("Hausbau-TODOS.note")
    let markURL = examples.appendingPathComponent("Elektroplanung Schäfer 25082026.pdf.mark")

    override func setUpWithError() throws {
        // The sample files are personal and not committed; skip when they aren't present.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: noteURL.path)
                          && FileManager.default.fileExists(atPath: markURL.path),
                          "example_files/ not present")
    }

    func testParsesNote() throws {
        let file = try SNFile(url: noteURL)
        XCTAssertEqual(file.fileType, .note)
        XCTAssertEqual(file.formatVersion, 20260016)
        XCTAssertEqual(file.deviceWidth, 1920)
        XCTAssertEqual(file.deviceHeight, 2560)
        XCTAssertEqual(file.pages.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(file.pages[0].layersBottomUp.map(\.name), ["BGLAYER", "LAYER1", "MAINLAYER"])
    }

    func testParsesMark() throws {
        let file = try SNFile(url: markURL)
        XCTAssertEqual(file.fileType, .mark)
        XCTAssertEqual(file.pages.count, 2)
        for page in file.pages {
            XCTAssertEqual(page.visibleLayers(fileType: .mark).map(\.name), ["MAINLAYER"])
        }
        XCTAssertEqual(SNFile.companionPDFURL(forMark: markURL).lastPathComponent, "Elektroplanung Schäfer 25082026.pdf")
    }

    func testEveryLayerDecodesToFullPage() throws {
        for url in [noteURL, markURL] {
            let file = try SNFile(url: url)
            for page in file.pages {
                for layer in page.layers {
                    let bitmap = try file.block(at: XCTUnwrap(layer.bitmapAddress))
                    let result = RLEDecoder.decode(bitmap, width: page.width, height: page.height)
                    XCTAssertEqual(result.decodedCount, page.width * page.height,
                                   "\(url.lastPathComponent) page \(page.number) \(layer.name)")
                }
            }
        }
    }

    func testLayerInfoBothEncodings() throws {
        let file = try SNFile(url: noteURL)
        // Page 1 stores LAYERINFO base64-encoded, page 2 as JSON with '#' for ':'.
        let p1 = try XCTUnwrap(file.pages[0].layerInfo)
        let p2 = try XCTUnwrap(file.pages[1].layerInfo)
        XCTAssertEqual(p1.count, 5)
        XCTAssertEqual(p2.count, 5)
        XCTAssertEqual(file.pages[0].visibleLayers(fileType: .note).map(\.name), ["BGLAYER", "LAYER1", "MAINLAYER"])
        XCTAssertEqual(file.pages[1].visibleLayers(fileType: .note).map(\.name), ["BGLAYER", "MAINLAYER"])
    }

    func testRejectsGarbageAndTruncatedFiles() throws {
        XCTAssertThrowsError(try SNFile(data: Data("hello world, not a supernote file".utf8)))
        let data = try Data(contentsOf: noteURL)
        XCTAssertThrowsError(try SNFile(data: data.prefix(5000)))
        var corrupt = data
        corrupt.replaceSubrange(corrupt.count - 4..<corrupt.count, with: [0xff, 0xff, 0xff, 0x7f])
        XCTAssertThrowsError(try SNFile(data: corrupt))
    }

    func testRendersPDFs() throws {
        let note = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: PDFRenderer.render(contentsOf: noteURL) as CFData)!))
        XCTAssertEqual(note.numberOfPages, 4)
        let mark = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: PDFRenderer.render(contentsOf: markURL) as CFData)!))
        XCTAssertEqual(mark.numberOfPages, 2)
    }

    func testParsesStrokes() throws {
        let note = try SNFile(url: noteURL)
        let strokes = try note.pages.map { try XCTUnwrap($0.strokes(in: note)) }
        XCTAssertEqual(strokes.map(\.count), [491, 181, 102, 315])
        XCTAssertEqual(strokes[0].filter(\.isDeleted).count, 3)
        XCTAssertEqual(strokes[0].filter(\.isEraser).count, 2)
        XCTAssertEqual(strokes[0].filter { $0.layer == 1 }.count, 5)
        XCTAssertTrue(strokes[0].filter { $0.layer == 1 }.allSatisfy(\.isMarker))

        let mark = try SNFile(url: markURL)
        XCTAssertEqual(try mark.pages.map { try XCTUnwrap($0.strokes(in: mark)).count }, [189, 151])
    }

    func testVectorStrokesReproduceEveryBitmapLayer() throws {
        for url in [noteURL, markURL] {
            try assertVectorStrokesReproduceBitmaps(url)
        }
    }

    func testCoverageGuardRejectsMissingStrokes() throws {
        let file = try SNFile(url: noteURL)
        let page = file.pages[1]
        let layer = try XCTUnwrap(page.layers.first { $0.name == "MAINLAYER" })
        let codes = try XCTUnwrap(LayerCompositor.codes(of: layer, page: page, in: file))
        let strokes = try XCTUnwrap(page.strokes(in: file))
        XCTAssertFalse(VectorRenderer.covers(Array(strokes.prefix(strokes.count / 2)), codes: codes,
                                             width: page.width, height: page.height))
    }

    func testCoverageGuardRejectsStrokesOutsideInk() throws {
        let file = try SNFile(url: noteURL)
        let page = file.pages[1]
        let layer = try XCTUnwrap(page.layers.first { $0.name == "MAINLAYER" })
        let codes = try XCTUnwrap(LayerCompositor.codes(of: layer, page: page, in: file))
        let strokes = try XCTUnwrap(page.strokes(in: file)).filter { $0.layer == 0 }
        XCTAssertTrue(VectorRenderer.covers(strokes, codes: codes, width: page.width, height: page.height))
        // A filled bar over empty paper, like a text box frame mistaken for ink.
        let bar = SNStroke(penType: 1, color: 0x61, width: 100, layer: 0, isDeleted: false,
                           path: CGPath(rect: CGRect(x: 100, y: 2300, width: 900, height: 64), transform: nil),
                           textBox: nil)
        XCTAssertFalse(VectorRenderer.covers(strokes + [bar], codes: codes, width: page.width, height: page.height))
    }

    func testCorruptStrokeDataFallsBackToNil() throws {
        let data = try Data(contentsOf: noteURL)
        let file = try SNFile(url: noteURL)
        let address = try XCTUnwrap(file.pages[1].metadata["TOTALPATH"].flatMap(Int.init))
        var corrupt = data
        // Claim a huge first record so parsing runs past the block.
        corrupt.replaceSubrange(address + 8..<address + 12, with: [0xff, 0xff, 0xff, 0x0f])
        let corruptFile = try SNFile(data: corrupt)
        XCTAssertNil(corruptFile.pages[1].strokes(in: corruptFile))
        // Rendering still works via bitmaps.
        XCTAssertNoThrow(try PDFRenderer.renderNote(corruptFile))
    }

    func testRecognizesHandwriting() throws {
        let file = try SNFile(url: noteURL)
        let words = TextLayer.recognize(file: file, cacheDirectory: nil)
        let page1 = try XCTUnwrap(words[1])
        XCTAssertGreaterThan(page1.count, 10)
        XCTAssertTrue(page1.allSatisfy { $0.box.minX >= 0 && $0.box.maxX <= 1.001 && $0.box.minY >= 0 && $0.box.maxY <= 1.001 })
    }

    func testMarkWithoutCompanionStillRenders() throws {
        let file = try SNFile(url: markURL)
        let data = try PDFRenderer.renderMark(file, companion: nil, companionName: "missing.pdf")
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(doc.numberOfPages, 2)
    }
}

/// Uses the demo files committed in `examples/`, so these run everywhere.
final class ExampleFileTests: XCTestCase {
    static let examples = SupernoteKitTests.repo.appendingPathComponent("examples")
    /// Manta note with a typed text box ("Maybe they are also helpful for others") half covered by a marker.
    let textBoxURL = examples.appendingPathComponent("Example Note.note")
    let markURL = examples.appendingPathComponent("2026-03-22 Garmin Connect Integration.pdf.mark")
    static let typedText = "Maybe they are also helpful for others"

    func testVectorStrokesReproduceEveryBitmapLayer() throws {
        for url in [textBoxURL, markURL] {
            try assertVectorStrokesReproduceBitmaps(url)
        }
    }

    func testParsesTextBox() throws {
        let file = try SNFile(url: textBoxURL)
        let strokes = try XCTUnwrap(file.pages[0].strokes(in: file))
        let boxes = strokes.filter { $0.textBox != nil }
        XCTAssertEqual(boxes.count, 1)
        let box = try XCTUnwrap(boxes.first?.textBox)
        XCTAssertEqual(box.text, Self.typedText)
        XCTAssertEqual(box.rect, CGRect(x: 124, y: 1122, width: 873, height: 64))
        XCTAssertEqual(box.fontSize, 48)
        XCTAssertFalse(boxes[0].isInk)
        XCTAssertEqual(strokes.filter(\.isInk).count, strokes.count - 1)
    }

    func testTextBoxRendersAsText() throws {
        let data = try PDFRenderer.render(contentsOf: textBoxURL)
        let text = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0)?.string)
        XCTAssertTrue(text.contains(Self.typedText), text)

        // Rasterize at device resolution: the box must hold glyphs, not a solid bar.
        let page = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.page(at: 1))
        let (w, h) = (1920, 2560)
        var pixels = [UInt8](repeating: 255, count: w * h)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            let box = page.getBoxRect(.mediaBox)
            ctx.scaleBy(x: CGFloat(w) / box.width, y: CGFloat(h) / box.height)
            ctx.drawPDFPage(page)
        }
        var dark = 0, total = 0
        for y in 1122..<1186 {
            for x in 124..<997 {
                total += 1
                if pixels[y * w + x] < 128 { dark += 1 }  // memory row 0 is the top row
            }
        }
        XCTAssertGreaterThan(dark, total / 50, "no text drawn")
        XCTAssertLessThan(dark, total / 3, "text box drawn as a bar")
    }
}

func assertVectorStrokesReproduceBitmaps(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let snFile = try SNFile(url: url)
    for page in snFile.pages {
        let strokes = try XCTUnwrap(page.strokes(in: snFile), file: file, line: line)
        for layer in page.visibleLayers(fileType: snFile.fileType) where layer.name != "BGLAYER" {
            let index = try XCTUnwrap(SNStroke.layerIndex(forLayerName: layer.name), file: file, line: line)
            let codes = try XCTUnwrap(LayerCompositor.codes(of: layer, page: page, in: snFile), file: file, line: line)
            let layerStrokes = strokes.filter { $0.layer == index }
            XCTAssertTrue(VectorRenderer.covers(layerStrokes, codes: codes, width: page.width, height: page.height,
                                                ignoring: layerStrokes.compactMap(\.textBox?.rect)),
                          "\(url.lastPathComponent) page \(page.number) \(layer.name)", file: file, line: line)
        }
    }
}

/// Measurement logic doesn't need the example files.
final class MeasurementTests: XCTestCase {
    func testParsesLengths() throws {
        XCTAssertEqual(try XCTUnwrap(Length.parse("2,23 m")), 2.23, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Length.parse("2.23")), 2.23, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Length.parse("223 cm")), 2.23, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Length.parse("2230mm")), 2.23, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Length.parse(" 5 M ")), 5, accuracy: 1e-9)
        XCTAssertNil(Length.parse(""))
        XCTAssertNil(Length.parse("abc"))
        XCTAssertNil(Length.parse("0 m"))
        XCTAssertNil(Length.parse("-2 m"))
    }

    func testFormatsLengths() {
        let de = Locale(identifier: "de_DE"), en = Locale(identifier: "en_US")
        XCTAssertEqual(Length.format(3.4712, locale: de), "3,47 m")
        XCTAssertEqual(Length.format(3.4712, locale: en), "3.47 m")
        XCTAssertEqual(Length.format(0.345, locale: de), "34,5 cm")
        XCTAssertEqual(Length.format(1234.5, locale: de), "1234,50 m")
    }

    func testScaleMath() throws {
        var state = MeasureState()
        let line = MeasureLine(pageIndex: 0, start: .zero, end: CGPoint(x: 150, y: 200))  // 250 pt
        XCTAssertNil(state.meters(of: line))

        state.calibrate(Calibration(pageIndex: 0, start: .zero, end: CGPoint(x: 100, y: 0), meters: 2))
        XCTAssertEqual(try XCTUnwrap(state.meters(of: line)), 5, accuracy: 1e-9)

        // Another page without its own calibration uses the latest one.
        let other = MeasureLine(pageIndex: 3, start: .zero, end: CGPoint(x: 0, y: 50))
        let scale = try XCTUnwrap(state.scale(forPage: 3))
        XCTAssertEqual(scale.fromPage, 0)
        XCTAssertEqual(try XCTUnwrap(state.meters(of: other)), 1, accuracy: 1e-9)

        // Recalibrating a page replaces its calibration; removing it drops the scale.
        state.calibrate(Calibration(pageIndex: 0, start: .zero, end: CGPoint(x: 100, y: 0), meters: 4))
        XCTAssertEqual(state.calibrations.count, 1)
        XCTAssertEqual(try XCTUnwrap(state.meters(of: line)), 10, accuracy: 1e-9)
        state.remove(id: state.calibrations[0].id)
        XCTAssertNil(state.scale(forPage: 0))
    }
}
