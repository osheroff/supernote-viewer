import CoreGraphics
import Foundation
import XCTest
@testable import SupernoteKit

final class SupernoteKitTests: XCTestCase {
    static let examples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("example_files")
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
            let file = try SNFile(url: url)
            for page in file.pages {
                let strokes = try XCTUnwrap(page.strokes(in: file))
                for layer in page.visibleLayers(fileType: file.fileType) where layer.name != "BGLAYER" {
                    let index = try XCTUnwrap(SNStroke.layerIndex(forLayerName: layer.name))
                    let codes = try XCTUnwrap(LayerCompositor.codes(of: layer, page: page, in: file))
                    XCTAssertTrue(VectorRenderer.covers(strokes.filter { $0.layer == index }, codes: codes,
                                                        width: page.width, height: page.height),
                                  "\(url.lastPathComponent) page \(page.number) \(layer.name)")
                }
            }
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
