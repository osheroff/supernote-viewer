import CoreGraphics
import Foundation
import XCTest
@testable import SupernoteKit

/// Uses the fixtures from supernote-typescript in `Tests/Fixtures/supernote-typescript/`, which
/// cover devices and format versions beyond the Manta. Expected counts marked "device export"
/// match the number of paths in Supernote's own PDF export of that page (per upstream's notes).
final class UpstreamFixtureTests: XCTestCase {
    static let fixtures = SupernoteKitTests.repo.appendingPathComponent("SupernoteKit/Tests/Fixtures/supernote-typescript")

    /// Every fixture with the number of pages it renders to.
    static let pageCounts = [
        "erase-n6-20230015-horizontal-1270.note": 1,
        "sticker-n5-20260016-plugin-artwork.note": 3,
        "erase-n5-20260016-mixed-colors.note": 2,
        "test-a5x-20220011-old-pen-ids.note": 2,
        "heading-n5-20260016-backgrounds-marker.note": 3,
        "line-n5-20260016-ruler-tool.note": 3,
        "erase-n5-20260016-no-white-pen.note": 1,
        "caligraphy-n5-20260016-widths-erase.note": 4,
        "stroke-n5-20260016-isolation-tools-colors-widths.note": 5,
        "layout-n5-20230015-horizontal-1090.note": 1,
        "digest-n5-20230015-test.mark": 1,
        "blank-a6x-3.26.40-two-pages.note": 2,
        "render-n6-20230015-moonchild-user-bg.note": 1,
    ]

    static func url(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    func testEveryFixtureParsesAndRenders() throws {
        for (name, pageCount) in Self.pageCounts {
            let file = try SNFile(url: Self.url(name))
            for page in file.pages where page.metadata.address("TOTALPATH") != nil {
                XCTAssertNotNil(page.strokes(in: file), "\(name) page \(page.number)")
            }
            let pdf = try PDFRenderer.render(contentsOf: Self.url(name))
            let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: pdf as CFData)!), name)
            XCTAssertEqual(doc.numberOfPages, pageCount, name)
        }
    }

    func testDeviceSizesAndOrientation() throws {
        func size(_ name: String) throws -> [Int] {
            let page = try XCTUnwrap(SNFile(url: Self.url(name)).pages.first)
            return [page.width, page.height]
        }
        XCTAssertEqual(try size("erase-n6-20230015-horizontal-1270.note"), [1872, 1404])
        XCTAssertEqual(try size("layout-n5-20230015-horizontal-1090.note"), [2560, 1920])
        XCTAssertEqual(try size("test-a5x-20220011-old-pen-ids.note"), [1404, 1872])
    }

    func testStrokeCounts() throws {
        func strokes(_ name: String) throws -> [[SNStroke]] {
            let file = try SNFile(url: Self.url(name))
            return file.pages.map { $0.strokes(in: file) ?? [] }
        }

        // Records with disable areas or epa data; these failed to parse before.
        let n6 = try strokes("erase-n6-20230015-horizontal-1270.note")[0]
        XCTAssertEqual(n6.filter(\.isInk).count, 61)  // device export
        XCTAssertEqual(n6.filter(\.isDeleted).count, 21)
        XCTAssertEqual(try strokes("sticker-n5-20260016-plugin-artwork.note")[0].filter(\.isInk).count, 5)  // device export

        let a5x = try SNFile(url: Self.url("test-a5x-20220011-old-pen-ids.note"))
        XCTAssertEqual(a5x.pages.map { $0.strokes(in: a5x)?.count }, [58, 30])
        XCTAssertEqual(a5x.pages[0].visibleLayers(fileType: .note).map(\.name), ["BGLAYER", "MAINLAYER", "LAYER1"])
        XCTAssertTrue(try XCTUnwrap(a5x.pages[0].strokes(in: a5x)).contains { $0.layer == 1 })

        XCTAssertEqual(try strokes("erase-n5-20260016-no-white-pen.note")[0].filter(\.isInk).count, 0)
        XCTAssertEqual(try strokes("line-n5-20260016-ruler-tool.note").map { $0.filter(\.isInk).count }, [6, 2, 0])
    }

    /// Nomad, A5X and old ink pen (pen type 1) pages aren't listed: their outlines don't reproduce
    /// the bitmap within the coverage tolerance, so they render from bitmaps.
    func testVectorStrokesReproduceEveryBitmapLayer() throws {
        for name in ["erase-n6-20230015-horizontal-1270.note", "sticker-n5-20260016-plugin-artwork.note",
                     "erase-n5-20260016-mixed-colors.note", "line-n5-20260016-ruler-tool.note",
                     "erase-n5-20260016-no-white-pen.note", "caligraphy-n5-20260016-widths-erase.note",
                     "digest-n5-20230015-test.mark"] {
            try assertVectorStrokesReproduceBitmaps(Self.url(name))
        }
    }

    /// The custom template is a PNG in a layer without LAYERPROTOCOL; decoded as RLE it rendered
    /// as a band of gray and black stripes across the top of the page.
    func testUndeclaredPNGBackground() throws {
        let file = try SNFile(url: Self.url("render-n6-20230015-moonchild-user-bg.note"))
        let page = file.pages[0]
        let bg = try XCTUnwrap(page.layers.first { $0.name == "BGLAYER" })
        XCTAssertEqual(bg.layerProtocol, "PNG")
        XCTAssertEqual(page.layers.first { $0.name == "MAINLAYER" }?.layerProtocol, "RATTA_RLE")
        XCTAssertTrue(try LayerCompositor.codes(of: bg, page: page, in: file) == nil, "PNG decoded as RLE")

        // The 7mm lined template leaves most of the top of the page white.
        let image = try XCTUnwrap(LayerCompositor.render(page: page, in: file, background: .white,
                                                         include: { $0.name == "BGLAYER" }))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        let top = pixels.prefix(page.width * 300)
        XCTAssertGreaterThan(Double(top.filter { $0 > 0xf0 }.count) / Double(top.count), 0.8)
    }

    func testHeadingFramesAreNotText() throws {
        let file = try SNFile(url: Self.url("heading-n5-20260016-backgrounds-marker.note"))
        let page = file.pages[1]
        let frames = try XCTUnwrap(page.strokes(in: file)).compactMap(\.textBox)
        XCTAssertEqual(frames.count, 4)
        XCTAssertTrue(frames.allSatisfy { $0.text == "none" })
        XCTAssertTrue(page.textBoxes(in: file).isEmpty)
        XCTAssertTrue(PDFRenderer.textWords(of: page, in: file, recognized: nil).isEmpty)
    }
}
