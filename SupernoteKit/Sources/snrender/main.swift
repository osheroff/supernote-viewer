import CoreGraphics
import Foundation
import ImageIO
import SupernoteKit
import UniformTypeIdentifiers

// Usage: snrender <file.note|file.pdf.mark> <out.pdf> [--png <dir>] [--dpi <n>]
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: snrender <input> <out.pdf> [--png <dir>] [--dpi <n>]\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let pngDir = args.firstIndex(of: "--png").map { URL(fileURLWithPath: args[$0 + 1]) }
let dpi = args.firstIndex(of: "--dpi").flatMap { Double(args[$0 + 1]) } ?? 100

do {
    let file = try SNFile(url: input)
    print("\(file.fileType) \(file.signature) \(file.header["APPLY_EQUIPMENT"] ?? "?") \(file.deviceWidth)x\(file.deviceHeight), \(file.pages.count) page(s)")
    for page in file.pages {
        let layers = page.visibleLayers(fileType: file.fileType).map(\.name).joined(separator: ",")
        print("  page \(page.number): \(page.width)x\(page.height) style=\(page.style) visible=[\(layers)]")
    }

    let start = Date()
    let pdf = try PDFRenderer.render(contentsOf: input)
    try pdf.write(to: output)
    print(String(format: "wrote %@ (%d KB) in %.2fs", output.path, pdf.count / 1024, Date().timeIntervalSince(start)))

    if let pngDir {
        try FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)
        let doc = CGPDFDocument(output as CFURL)!
        for i in 1...doc.numberOfPages {
            let page = doc.page(at: i)!
            let box = page.getBoxRect(.mediaBox)
            let scale = dpi / 72
            let w = Int(box.width * scale), h = Int(box.height * scale)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            let url = pngDir.appendingPathComponent(String(format: "page-%02d.png", i))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(dest)
            print("  \(url.path)")
        }
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
