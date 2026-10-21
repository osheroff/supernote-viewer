import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import SupernoteKit

/// Titles marked on the device and the PDF outline (table of contents) made from them.
final class TitleTests: XCTestCase {
    static let headingURL = UpstreamFixtureTests.url("heading-n5-20260016-backgrounds-marker.note")
    static let a5xURL = UpstreamFixtureTests.url("test-a5x-20220011-old-pen-ids.note")
    /// Manta note with three titles in different styles: "Heading", "Another Title!", "Allright testing titles".
    static let exampleURL = ExampleFileTests.examples.appendingPathComponent("Example Titles.note")

    // MARK: - Parsing

    func testParsesTitles() throws {
        let heading = try SNFile(url: Self.headingURL)
        XCTAssertEqual(heading.titles.map(\.pageNumber), [2, 2, 2, 2])
        XCTAssertEqual(heading.titles.map(\.rect), [CGRect(x: 500, y: 329, width: 356, height: 148),
                                                    CGRect(x: 480, y: 691, width: 582, height: 178),
                                                    CGRect(x: 490, y: 1016, width: 284, height: 125),
                                                    CGRect(x: 508, y: 1295, width: 290, height: 118)])
        XCTAssertEqual(heading.titles.map(\.level), [1, 1, 1, 1])

        // TITLERECTORI differs here (padded to 180 px high); TITLERECT is the box around the ink.
        let a5x = try SNFile(url: Self.a5xURL)
        XCTAssertEqual(a5x.titles.map(\.pageNumber), [1, 2])
        XCTAssertEqual(a5x.titles.map(\.rect), [CGRect(x: 121, y: 100, width: 341, height: 93),
                                                CGRect(x: 111, y: 323, width: 424, height: 88)])

        let example = try SNFile(url: Self.exampleURL)
        XCTAssertEqual(example.titles.map(\.pageNumber), [1, 1, 1])
        XCTAssertEqual(example.titles.map(\.rect.minY), [179, 1589, 2185])
    }

    func testFilesWithoutTitles() throws {
        for url in [ExampleFileTests.examples.appendingPathComponent("Example Note.note"),
                    UpstreamFixtureTests.url("erase-n5-20260016-mixed-colors.note"),
                    UpstreamFixtureTests.url("digest-n5-20230015-test.mark")] {
            XCTAssertTrue(try SNFile(url: url).titles.isEmpty, url.lastPathComponent)
        }
    }

    func testTitleKeyAndMetadata() throws {
        func title(_ key: String, _ metadata: String) -> SNTitle? {
            SNTitle(key: key, metadata: SNMetadata(Data(metadata.utf8)))
        }
        let rect = "<TITLERECT:10,20,30,40>"
        let parsed = try XCTUnwrap(title("TITLE_000312340567", rect + "<TITLELEVEL:2>"))
        XCTAssertEqual(parsed.pageNumber, 3)
        XCTAssertEqual(parsed.level, 2)
        XCTAssertEqual(parsed.rect, CGRect(x: 10, y: 20, width: 30, height: 40))

        // Older firmware keys hold only page and y.
        XCTAssertEqual(title("TITLE_00020277", rect)?.pageNumber, 2)
        XCTAssertNil(title("TITLE_", rect))
        XCTAssertNil(title("TITLE_12", rect))
        XCTAssertNil(title("TITLE_abcd0000", rect))
        XCTAssertNil(title("TITLE_00000100", rect), "page 0")

        XCTAssertNil(title("TITLE_00010100", ""))
        XCTAssertNil(title("TITLE_00010100", "<TITLERECT:10,20,0,40>"))
        XCTAssertNil(title("TITLE_00010100", "<TITLERECT:10,20,30>"))
        XCTAssertEqual(title("TITLE_00010100", "<TITLERECT:none><TITLERECTORI:1,2,3,4>")?.rect,
                       CGRect(x: 1, y: 2, width: 3, height: 4))

        XCTAssertEqual(title("TITLE_00010100", rect)?.level, 1)
        XCTAssertEqual(title("TITLE_00010100", rect + "<TITLELEVEL:0>")?.level, 1)
        XCTAssertEqual(title("TITLE_00010100", rect + "<TITLELEVEL:none>")?.level, 1)
    }

    /// A title block pointing past the end of the file is left out; the rest of the file still opens.
    func testUnreadableTitleBlockIsSkipped() throws {
        var data = try Data(contentsOf: Self.headingURL)
        let range = try XCTUnwrap(data.range(of: Data("<TITLE_000206910480:16295>".utf8)))
        // Same length, so the footer block stays intact; the file is 375999 bytes.
        data.replaceSubrange(range, with: Data("<TITLE_0002069104:999999> ".utf8))
        let file = try SNFile(data: data)
        XCTAssertEqual(file.titles.count, 3)
        XCTAssertEqual(file.titles.map(\.rect.minY), [329, 1016, 1295])
    }

    // MARK: - Outline

    private func title(page: Int, _ rect: CGRect, level: Int = 1) -> SNTitle {
        let metadata = "<TITLERECT:\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))>"
            + "<TITLELEVEL:\(level)>"
        return SNTitle(key: String(format: "TITLE_%04d00000000", page), metadata: SNMetadata(Data(metadata.utf8)))!
    }

    /// A word centered at (x, y) in page pixels (origin top-left) of a 1000×2000 page.
    private func word(_ text: String, x: CGFloat, y: CGFloat) -> RecognizedWord {
        RecognizedWord(text: text, box: CGRect(x: x / 1000 - 0.02, y: 1 - y / 2000 - 0.005, width: 0.04, height: 0.01))
    }

    private func page(_ index: Int, _ words: [RecognizedWord] = []) -> PDFRenderer.OutlinePage {
        PDFRenderer.OutlinePage(index: index, width: 1000, height: 2000, words: words)
    }

    /// Entries as "label@page", children indented.
    private func describe(_ outline: [String: Any]?, depth: Int = 0) -> [String] {
        let children = outline?[kCGPDFOutlineChildren as String] as? [[String: Any]] ?? []
        return children.flatMap { entry in
            let label = entry[kCGPDFOutlineTitle as String] as? String ?? "?"
            let page = entry[kCGPDFOutlineDestination as String] as? Int ?? 0
            return [String(repeating: "  ", count: depth) + "\(label)@\(page)"] + describe(entry, depth: depth + 1)
        }
    }

    func testOutlineLabelsTitlesWithTheWordsInside() {
        let titleRect = CGRect(x: 100, y: 200, width: 400, height: 100)
        let words = [
            word("Big", x: 200, y: 250), word("Heading", x: 400, y: 250),
            word("Beside", x: 700, y: 250),   // right of the title
            word("Below", x: 200, y: 400),
            word("Mirrored", x: 200, y: 1750), // where the title would be with y not flipped
        ]
        let outline = PDFRenderer.outline(titles: [title(page: 1, titleRect)], pages: [1: page(1, words)])
        XCTAssertEqual(describe(outline), ["Big Heading@1"])
    }

    func testOutlineFallsBackToPageNumber() {
        // Page numbers with a gap: page 5 is the third page of the PDF.
        let outline = PDFRenderer.outline(titles: [title(page: 5, CGRect(x: 0, y: 0, width: 100, height: 100))],
                                          pages: [5: page(3)])
        XCTAssertEqual(describe(outline), ["Page 3@3"])
    }

    func testOutlineNestsByLevel() {
        let titles = [(1, 1), (1, 2), (1, 2), (2, 3), (2, 1), (3, 2)].enumerated().map { i, pageAndLevel in
            title(page: pageAndLevel.0, CGRect(x: 0, y: CGFloat(i) * 100, width: 100, height: 50), level: pageAndLevel.1)
        }
        let pages = [1: page(1), 2: page(2), 3: page(3)]
        XCTAssertEqual(describe(PDFRenderer.outline(titles: titles, pages: pages)), [
            "Page 1@1",
            "  Page 1@1",
            "  Page 1@1",
            "    Page 2@2",
            "Page 2@2",
            "  Page 3@3",
        ])

        // A first title below level 1 still becomes a top-level entry.
        let deep = PDFRenderer.outline(titles: [title(page: 1, .init(x: 0, y: 0, width: 9, height: 9), level: 3),
                                                title(page: 1, .init(x: 0, y: 50, width: 9, height: 9), level: 1)],
                                       pages: pages)
        XCTAssertEqual(describe(deep), ["Page 1@1", "Page 1@1"])
    }

    func testOutlineLeavesOutTitlesOnMissingPages() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(PDFRenderer.outline(titles: [], pages: [1: page(1)]))
        XCTAssertNil(PDFRenderer.outline(titles: [title(page: 2, rect)], pages: [1: page(1)]))
        XCTAssertEqual(describe(PDFRenderer.outline(titles: [title(page: 2, rect), title(page: 1, rect)],
                                                    pages: [1: page(1)])), ["Page 1@1"])
    }

    // MARK: - Rendering

    /// Outline entries of a rendered PDF as (label, 1-based page).
    private func renderedOutline(_ url: URL, textLayer: Bool = true) throws -> [(label: String, page: Int)]? {
        let data = try PDFRenderer.render(contentsOf: url, options: RenderOptions(textLayer: textLayer))
        let doc = try XCTUnwrap(PDFDocument(data: data))
        guard let root = doc.outlineRoot else { return nil }
        return (0..<root.numberOfChildren).compactMap { root.child(at: $0) }.map { entry in
            XCTAssertEqual(entry.numberOfChildren, 0)
            return (entry.label ?? "", entry.destination?.page.map { doc.index(for: $0) + 1 } ?? 0)
        }
    }

    func testRenderedOutline() throws {
        let heading = try XCTUnwrap(renderedOutline(Self.headingURL))
        XCTAssertEqual(heading.map(\.page), [2, 2, 2, 2])
        XCTAssertTrue(heading[0].label.lowercased().contains("black"), heading[0].label)
        XCTAssertTrue(heading[1].label.lowercased().contains("grey"), heading[1].label)
        XCTAssertTrue(heading[2].label.lowercased().contains("grey"), heading[2].label)
        XCTAssertFalse(heading[3].label.isEmpty)

        let a5x = try XCTUnwrap(renderedOutline(Self.a5xURL))
        XCTAssertEqual(a5x.map(\.page), [1, 2])
        XCTAssertTrue(a5x.allSatisfy { $0.label.lowercased().contains("title") }, "\(a5x.map(\.label))")

        let example = try XCTUnwrap(renderedOutline(Self.exampleURL))
        XCTAssertEqual(example.map(\.page), [1, 1, 1])
        XCTAssertTrue(example[0].label.lowercased().hasPrefix("head"), example[0].label)
        XCTAssertTrue(example[1].label.lowercased().contains("another"), example[1].label)
        XCTAssertFalse(example[2].label.isEmpty)
    }

    /// Titles are labeled from the text layer, so without it (Quick Look) there is no outline and
    /// no handwriting recognition at all.
    func testNoOutlineWithoutTextLayer() throws {
        XCTAssertNil(try renderedOutline(Self.headingURL, textLayer: false))
        XCTAssertNil(try renderedOutline(Self.exampleURL, textLayer: false))
    }

    func testNoOutlineWithoutTitles() throws {
        XCTAssertNil(try renderedOutline(ExampleFileTests.examples.appendingPathComponent("Example Note.note")))
        XCTAssertNil(try renderedOutline(UpstreamFixtureTests.url("digest-n5-20230015-test.mark")))
    }
}
