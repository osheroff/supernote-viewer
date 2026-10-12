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
        XCTAssertTrue(LayerCompositor.codes(of: bg, page: page, in: file) == nil, "PNG decoded as RLE")

        // The 7mm lined template leaves most of the top of the page white.
        let image = try XCTUnwrap(LayerCompositor.render(page: page, in: file, background: .white,
                                                         include: { $0.name == "BGLAYER" }))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        let top = pixels.prefix(page.width * 300)
        XCTAssertGreaterThan(Double(top.filter { $0 > 0xf0 }.count) / Double(top.count), 0.8)
    }

    /// Some firmware (seen on A5X, 20260016) declares RATTA_RLE for custom template PNGs.
    func testPNGSignatureOverridesDeclaredProtocol() {
        func block(_ bytes: [UInt8]) -> Data {
            var length = UInt32(bytes.count).littleEndian
            return Data(bytes: &length, count: 4) + Data(bytes)
        }
        let png = block([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00])
        let rle = block([0x62, 0xff, 0x62, 0xff, 0x61, 0x00, 0x62, 0x10, 0x61, 0x00])
        XCTAssertEqual(SNFile.layerProtocol(declared: "RATTA_RLE", bitmapAt: 0, in: png), "PNG")
        XCTAssertEqual(SNFile.layerProtocol(declared: nil, bitmapAt: 0, in: png), "PNG")
        XCTAssertEqual(SNFile.layerProtocol(declared: "RATTA_RLE", bitmapAt: 0, in: rle), "RATTA_RLE")
        XCTAssertEqual(SNFile.layerProtocol(declared: nil, bitmapAt: 0, in: rle), "RATTA_RLE")
    }

    /// Every RLE layer written by a device describes exactly its page; the validation relies on it.
    func testEveryRLELayerPassesValidation() throws {
        for name in Self.pageCounts.keys {
            let file = try SNFile(url: Self.url(name))
            for page in file.pages {
                for layer in page.layers where layer.layerProtocol == "RATTA_RLE" && layer.bitmapAddress != nil {
                    XCTAssertNotNil(LayerCompositor.codes(of: layer, page: page, in: file),
                                    "\(name) page \(page.number) \(layer.name)")
                }
            }
        }
    }

    /// Bitmaps that are neither valid RLE nor an image are left out instead of drawn as stripes;
    /// handwriting layers are then drawn from their strokes.
    func testCorruptBitmapsAreLeftOut() throws {
        var data = try Data(contentsOf: Self.url("erase-n5-20260016-mixed-colors.note"))
        let file = try SNFile(data: data)
        var seed: UInt32 = 1
        for layer in file.pages[0].layers {
            let address = try XCTUnwrap(layer.bitmapAddress)
            let length = try file.block(at: address).count
            for i in (address + 4)..<(address + 4 + length) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                data[i] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        let corrupt = try SNFile(data: data)
        let page = corrupt.pages[0]
        for layer in page.layers {
            XCTAssertNil(LayerCompositor.content(of: layer, page: page, in: corrupt), layer.name)
        }
        let paper = try XCTUnwrap(LayerCompositor.render(page: page, in: corrupt, background: .white))
        XCTAssertTrue(try XCTUnwrap(paper.dataProvider?.data as Data?).allSatisfy { $0 == 255 })

        XCTAssertGreaterThan(try darkPixels(drawingInkOf: page, in: corrupt), 1000)
        XCTAssertNoThrow(try PDFRenderer.renderNote(corrupt))
    }

    /// A page or layer block pointing past the end of the file leaves that page blank or that layer
    /// out, instead of failing the whole file.
    func testUnreadableBlocksAreSkipped() throws {
        let original = try Data(contentsOf: Self.url("render-n6-20230015-moonchild-user-bg.note"))
        func replacing(_ tag: String, with replacement: String) throws -> Data {
            var data = original
            let range = try XCTUnwrap(data.range(of: Data(tag.utf8)))
            data.replaceSubrange(range, with: Data(replacement.utf8))
            return data
        }

        let noLayer = try SNFile(data: replacing("<MAINLAYER:280359>", with: "<MAINLAYER:999999>"))
        XCTAssertEqual(noLayer.pages[0].layers.map(\.name), ["BGLAYER"])
        XCTAssertNoThrow(try PDFRenderer.renderNote(noLayer))

        let noPage = try SNFile(data: replacing("<PAGE1:280444>", with: "<PAGE1:999999>"))
        XCTAssertEqual(noPage.pages.map(\.number), [1])
        XCTAssertTrue(noPage.pages[0].layers.isEmpty)
        let pdf = try PDFRenderer.renderNote(noPage)
        XCTAssertEqual(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages, 1)
    }

    /// Number of dark pixels `PDFRenderer.drawInk` paints for a page, at 1/4 scale.
    private func darkPixels(drawingInkOf page: SNPage, in file: SNFile) throws -> Int {
        let w = page.width / 4, h = page.height / 4
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        PDFRenderer.drawInk(of: page, in: file, ctx: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h),
                            options: RenderOptions())
        let pixels = try XCTUnwrap(ctx.makeImage()?.dataProvider?.data as Data?)
        return pixels.filter { $0 < 128 }.count
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
