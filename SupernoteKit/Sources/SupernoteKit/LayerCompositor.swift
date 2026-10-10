import CoreGraphics
import Foundation
import ImageIO

/// Composites a page's visible layers into a single image.
///
/// Ink is modelled as premultiplied gray + alpha. Opaque pens (and white ink) replace what is
/// below them; everything else — marker strokes and the anti-aliasing shades the firmware writes as
/// raw gray values — is black with alpha = 1 − gray/255, which equals a multiply blend of that gray.
/// That keeps highlighter strokes from hiding text, both on note templates and on annotated PDFs.
public enum LayerCompositor {
    public enum Background {
        /// Opaque white paper (for .note pages).
        case white
        /// Transparent, for overlaying on a PDF page (.mark files).
        case transparent
    }

    /// Ink for one color code: premultiplied gray value and alpha.
    struct Ink {
        var gray: UInt8
        var alpha: UInt8
        static let none = Ink(gray: 0, alpha: 0)
        static func opaque(_ g: UInt8) -> Ink { Ink(gray: g, alpha: 255) }
        static func multiply(_ g: UInt8) -> Ink { Ink(gray: 0, alpha: 255 - g) }
    }

    static func inkTable(x2: Bool, markFile: Bool) -> [Ink] {
        let darkGray: UInt8 = 0x9d, gray: UInt8 = 0xc9
        var t = [Ink](repeating: .none, count: 256)
        for v in 0...255 {
            // X2 firmware stores anti-aliasing pixels as their raw gray value.
            t[v] = x2 ? .multiply(UInt8(v)) : .none
        }
        t[0x62] = .none                         // transparent
        t[0x61] = .opaque(0x00)                 // black
        t[0x63] = .opaque(x2 ? 0x30 : darkGray) // dark gray (X2: compat value)
        t[0x64] = .opaque(x2 ? 0x50 : gray)     // gray (X2: compat value)
        t[0x65] = .opaque(0xfe)                 // white
        t[0x66] = .multiply(0x00)               // marker black
        t[0x67] = .multiply(darkGray)           // marker dark gray
        t[0x68] = .multiply(gray)               // marker gray
        if x2 {
            t[0x9d] = .opaque(darkGray)
            t[0xc9] = .opaque(gray)
            t[0x9e] = .multiply(darkGray)
            t[0xca] = .multiply(gray)
        }
        if markFile {
            // On PDFs, light inks are almost always highlighter; never let them cover the text.
            for c in [0x63, 0x64, 0x9d, 0xc9] { t[c] = .multiply(t[c].gray) }
        }
        return t
    }

    /// Decodes an RLE layer into one color code per pixel; nil for non-RLE or empty layers.
    public static func codes(of layer: SNLayer, page: SNPage, in file: SNFile) throws -> [UInt8]? {
        guard layer.layerProtocol == "RATTA_RLE", let address = layer.bitmapAddress else { return nil }
        let bitmap = try file.block(at: address)
        let allBlank = layer.name == "BGLAYER" && page.style == "style_white" && bitmap.count == 0x140e
        return RLEDecoder.decode(bitmap, width: page.width, height: page.height, allBlank: allBlank).codes
    }

    /// Renders a page's visible layers (optionally only those passing `include`).
    /// Returns nil if nothing is visible on a transparent page.
    public static func render(page: SNPage, in file: SNFile, background: Background,
                              include: (SNLayer) -> Bool = { _ in true }) throws -> CGImage? {
        let w = page.width, h = page.height, count = w * h
        let table = inkTable(x2: file.usesX2Colors, markFile: file.fileType == .mark)

        // Premultiplied gray and alpha planes.
        var dstGray = [UInt8](repeating: 0, count: count)
        var dstAlpha = [UInt8](repeating: 0, count: count)
        var anyInk = false

        for layer in page.visibleLayers(fileType: file.fileType) where include(layer) {
            guard let address = layer.bitmapAddress else { continue }
            let bitmap = try file.block(at: address)

            if layer.layerProtocol == "PNG" {
                guard let (g, a) = decodePNG(bitmap, width: w, height: h) else { continue }
                composite(srcGray: g, srcAlpha: a, dstGray: &dstGray, dstAlpha: &dstAlpha)
                anyInk = true
                continue
            }
            guard let codes = try Self.codes(of: layer, page: page, in: file) else { continue }
            anyInk = true

            dstGray.withUnsafeMutableBufferPointer { dg in
                dstAlpha.withUnsafeMutableBufferPointer { da in
                    codes.withUnsafeBufferPointer { src in
                        table.withUnsafeBufferPointer { ink in
                            for i in 0..<count {
                                let code = src[i]
                                if code == RLEDecoder.transparent { continue }
                                let s = ink[Int(code)]
                                if s.alpha == 0 { continue }
                                if s.alpha == 255 {
                                    dg[i] = s.gray; da[i] = 255
                                } else {
                                    let inv = 255 - Int(s.alpha)
                                    dg[i] = UInt8(Int(s.gray) + (Int(dg[i]) * inv + 127) / 255)
                                    da[i] = UInt8(Int(s.alpha) + (Int(da[i]) * inv + 127) / 255)
                                }
                            }
                        }
                    }
                }
            }
        }

        switch background {
        case .white:
            // Flatten onto white paper as an 8-bit grayscale image.
            var out = [UInt8](repeating: 255, count: count)
            for i in 0..<count {
                // Premultiplied over white: gray + (1 - alpha) * 255.
                let v: Int = Int(dstGray[i]) + 255 - Int(dstAlpha[i])
                out[i] = UInt8(clamping: v)
            }
            return makeImage(bytes: out, width: w, height: h, gray: true)

        case .transparent:
            guard anyInk else { return nil }
            var out = [UInt8](repeating: 0, count: count * 4)
            for i in 0..<count {
                let g = dstGray[i]
                out[i * 4] = g; out[i * 4 + 1] = g; out[i * 4 + 2] = g
                out[i * 4 + 3] = dstAlpha[i]
            }
            return makeImage(bytes: out, width: w, height: h, gray: false)
        }
    }

    private static func composite(srcGray: [UInt8], srcAlpha: [UInt8], dstGray: inout [UInt8], dstAlpha: inout [UInt8]) {
        for i in 0..<srcGray.count {
            let inv = 255 - Int(srcAlpha[i])
            dstGray[i] = UInt8(min(255, Int(srcGray[i]) + (Int(dstGray[i]) * inv + 127) / 255))
            dstAlpha[i] = UInt8(min(255, Int(srcAlpha[i]) + (Int(dstAlpha[i]) * inv + 127) / 255))
        }
    }

    /// Decodes a PNG layer (custom templates) into premultiplied gray + alpha planes.
    private static func decodePNG(_ data: Data, width: Int, height: Int) -> ([UInt8], [UInt8])? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var g = [UInt8](repeating: 0, count: width * height)
        var a = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(rgba[i * 4]), gg = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            g[i] = UInt8((r * 299 + gg * 587 + b * 114) / 1000)
            a[i] = rgba[i * 4 + 3]
        }
        return (g, a)
    }

    private static func makeImage(bytes: [UInt8], width: Int, height: Int, gray: Bool) -> CGImage? {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        if gray {
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
