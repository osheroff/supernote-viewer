import CoreGraphics
import CoreText
import Foundation

/// Options for PDF rendering.
public struct RenderOptions {
    /// Draw handwriting as vector outlines from the stroke data (falls back to bitmaps per layer).
    public var vector: Bool
    /// Add an invisible text layer with recognized handwriting.
    public var textLayer: Bool
    /// Where recognized text is cached between renders.
    public var ocrCacheDirectory: URL?
    /// Called with handwriting recognition progress (pages done, total), from any thread.
    public var progress: ((_ done: Int, _ total: Int) -> Void)?

    public init(vector: Bool = true, textLayer: Bool = false, ocrCacheDirectory: URL? = nil,
                progress: ((_ done: Int, _ total: Int) -> Void)? = nil) {
        self.vector = vector
        self.textLayer = textLayer
        self.ocrCacheDirectory = ocrCacheDirectory
        self.progress = progress
    }
}

/// Renders Supernote files to PDF data.
public enum PDFRenderer {
    /// Renders a `.note` or `.mark` file. For `.mark`, the companion PDF next to it is used when readable.
    public static func render(contentsOf url: URL, options: RenderOptions = RenderOptions()) throws -> Data {
        let file = try SNFile(url: url)
        switch file.fileType {
        case .note:
            return try renderNote(file, options: options)
        case .mark:
            let pdfURL = SNFile.companionPDFURL(forMark: url)
            return try renderMark(file, companion: openPDF(pdfURL), companionName: pdfURL.lastPathComponent,
                                  options: options)
        }
    }

    public static func renderNote(_ file: SNFile, options: RenderOptions = RenderOptions()) throws -> Data {
        let words = recognizeIfNeeded(file, options)
        return try makePDF { ctx in
            for page in file.pages {
                let rect = CGRect(origin: .zero, size: pointSize(page.width, page.height))
                beginPage(ctx, rect)
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(rect)
                try drawInk(of: page, in: file, ctx: ctx, rect: rect, options: options)
                if let w = words[page.number] { TextLayer.draw(w, in: ctx, rect: rect) }
                ctx.endPDFPage()
            }
        }
    }

    /// Draws each page of `companion` with the matching mark page's ink on top.
    /// Mark page n annotates PDF page n; the device shows the PDF page fitted and centered in its
    /// screen, so output pages have the device's aspect ratio to keep notes written in the margins.
    public static func renderMark(_ file: SNFile, companion: CGPDFDocument?, companionName: String,
                                  options: RenderOptions = RenderOptions()) throws -> Data {
        let marksByNumber = Dictionary(file.pages.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        let highlights = MarkHighlight.load(from: file)
        let words = recognizeIfNeeded(file, options)
        let pdfCount = companion?.numberOfPages ?? 0
        let pageCount = max(pdfCount, file.pages.map(\.number).max() ?? 0)

        return try makePDF { ctx in
            for number in 1...max(pageCount, 1) {
                let mark = marksByNumber[number]
                let deviceW = mark?.width ?? file.deviceWidth
                let deviceH = mark?.height ?? file.deviceHeight
                let pdfPage = number <= pdfCount ? companion?.page(at: number) : nil

                // Output page: the PDF page expanded to the device aspect ratio (or the device size).
                let box: CGRect
                var pageRect = CGRect.zero
                if let pdfPage {
                    let size = displayedSize(pdfPage)
                    let aspect = Double(deviceW) / Double(deviceH)
                    if size.width / size.height > aspect {
                        box = CGRect(x: 0, y: 0, width: size.width, height: size.width / aspect)
                    } else {
                        box = CGRect(x: 0, y: 0, width: size.height * aspect, height: size.height)
                    }
                    pageRect = CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2,
                                      width: size.width, height: size.height)
                } else {
                    box = CGRect(origin: .zero, size: pointSize(deviceW, deviceH))
                }

                beginPage(ctx, box)
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(box)

                if let pdfPage {
                    ctx.saveGState()
                    ctx.clip(to: pageRect)
                    ctx.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true))
                    ctx.drawPDFPage(pdfPage)
                    ctx.restoreGState()
                    for h in highlights[number - 1] ?? [] { h.draw(in: ctx, pageRect: pageRect) }
                }

                if let mark {
                    try drawInk(of: mark, in: file, ctx: ctx, rect: box, options: options)
                    if let w = words[mark.number] { TextLayer.draw(w, in: ctx, rect: box) }
                }

                if companion == nil && number == 1 {
                    drawNotice("Original PDF not found or not readable: \(companionName)", in: ctx, box: box)
                }
                ctx.endPDFPage()
            }
        }
    }

    /// Draws a page's visible layers bottom-up into `rect`. Each handwriting layer is drawn as
    /// vector outlines when the stroke data reproduces its bitmap, otherwise as the bitmap.
    /// The template background is always a bitmap.
    static func drawInk(of page: SNPage, in file: SNFile, ctx: CGContext, rect: CGRect, options: RenderOptions) throws {
        let strokes = options.vector ? page.strokes(in: file) : nil

        for layer in page.visibleLayers(fileType: file.fileType) {
            if let strokes, let index = SNStroke.layerIndex(forLayerName: layer.name),
               let codes = try LayerCompositor.codes(of: layer, page: page, in: file) {
                let layerStrokes = strokes.filter { $0.layer == index }
                if VectorRenderer.covers(layerStrokes, codes: codes, width: page.width, height: page.height) {
                    ctx.saveGState()
                    // Page pixels (origin top-left, y down) -> rect.
                    ctx.concatenate(CGAffineTransform(a: rect.width / CGFloat(page.width), b: 0, c: 0,
                                                      d: -rect.height / CGFloat(page.height),
                                                      tx: rect.minX, ty: rect.maxY))
                    VectorRenderer.draw(layerStrokes, in: ctx, file: file)
                    ctx.restoreGState()
                    continue
                }
            }
            if let image = try LayerCompositor.render(page: page, in: file, background: .transparent,
                                                      include: { $0.name == layer.name }) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: rect)
            }
        }
    }

    private static func recognizeIfNeeded(_ file: SNFile, _ options: RenderOptions) -> [Int: [RecognizedWord]] {
        guard options.textLayer else { return [:] }
        return TextLayer.recognize(file: file, cacheDirectory: options.ocrCacheDirectory, progress: options.progress)
    }

    public static func openPDF(_ url: URL) -> CGPDFDocument? {
        guard let doc = CGPDFDocument(url as CFURL) else { return nil }
        if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") { return nil }
        return doc
    }

    // MARK: - Helpers

    static func pointSize(_ w: Int, _ h: Int) -> CGSize {
        CGSize(width: Double(w) / SNFile.dpi * 72, height: Double(h) / SNFile.dpi * 72)
    }

    /// Crop box size after applying the page's /Rotate.
    static func displayedSize(_ page: CGPDFPage) -> CGSize {
        let r = page.getBoxRect(.cropBox)
        let angle = ((page.rotationAngle % 360) + 360) % 360
        return angle == 90 || angle == 270 ? CGSize(width: r.height, height: r.width) : r.size
    }

    private static func makePDF(_ body: (CGContext) throws -> Void) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw SNError.malformed("could not create PDF context")
        }
        try body(ctx)
        ctx.closePDF()
        return data as Data
    }

    private static func beginPage(_ ctx: CGContext, _ rect: CGRect) {
        var r = rect
        let boxData = Data(bytes: &r, count: MemoryLayout<CGRect>.size)
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
    }

    private static func drawNotice(_ text: String, in ctx: CGContext, box: CGRect) {
        let font = CTFontCreateUIFontForLanguage(.system, 9, nil)!
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.45, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: 12, y: box.height - 18)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
