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

    func testMarkWithoutCompanionStillRenders() throws {
        let file = try SNFile(url: markURL)
        let data = try PDFRenderer.renderMark(file, companion: nil, companionName: "missing.pdf")
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(doc.numberOfPages, 2)
    }
}
