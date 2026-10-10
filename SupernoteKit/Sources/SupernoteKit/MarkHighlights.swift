import CoreGraphics
import Foundation

/// Text highlights/underlines made with the PDF reader's selection tool, stored in the
/// header's HIGHLIGHTINFO block as base64 JSON: `{"<0-based page>": [annotation, ...]}`.
public struct MarkHighlight: Decodable {
    public enum Kind: Int { case highlight = 0, underline = 1 }

    public struct Rect: Decodable {
        // mupdf coordinates: PDF points, origin top-left, y downward.
        public let x0: Double
        public let x1: Double
        public let y0: Double
        public let y1: Double
    }

    public let annotationType: Int
    public let colorType: Int
    public let mupdfRectList: [Rect]

    public var kind: Kind? { Kind(rawValue: annotationType) }
    public var isRed: Bool { colorType == 4 }

    /// Highlights keyed by 0-based PDF page index. Returns an empty map when absent or unreadable.
    public static func load(from file: SNFile) -> [Int: [MarkHighlight]] {
        guard let raw = file.header["HIGHLIGHTINFO"], let address = Int(raw), address > 0,
              let block = try? file.block(at: address) else { return [:] }
        let text = String(decoding: block, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let json = Data(base64Encoded: text) ?? text.replacingOccurrences(of: "#", with: ":").data(using: .utf8)
        guard let json,
              let map = try? JSONDecoder().decode([String: [MarkHighlight]].self, from: json) else { return [:] }
        var result: [Int: [MarkHighlight]] = [:]
        for (key, value) in map {
            if let index = Int(key) { result[index] = value }
        }
        return result
    }

    /// Draws the highlight onto a PDF page placed at `pageRect` in the current context.
    func draw(in ctx: CGContext, pageRect: CGRect) {
        guard let kind else { return }
        let color = isRed
            ? CGColor(red: 1, green: 0.35, blue: 0.35, alpha: 1)
            : CGColor(red: 1, green: 0.92, blue: 0.2, alpha: 1)
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        for r in mupdfRectList {
            let rect = CGRect(x: pageRect.minX + r.x0, y: pageRect.maxY - r.y1,
                              width: r.x1 - r.x0, height: r.y1 - r.y0)
            switch kind {
            case .highlight:
                ctx.setFillColor(color)
                ctx.fill(rect)
            case .underline:
                ctx.setFillColor(color)
                ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, rect.height * 0.08)))
            }
        }
        ctx.restoreGState()
    }
}
