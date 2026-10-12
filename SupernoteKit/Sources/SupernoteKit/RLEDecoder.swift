import Foundation

/// Decoder for the RATTA_RLE layer bitmap protocol.
///
/// The stream is a sequence of `(colorCode, length)` byte pairs. A length with the high bit set is
/// held and combined with the next pair (if it has the same color) to form a long run.
/// Ported from supernotelib's `RattaRleDecoder` (decoder.py).
public enum RLEDecoder {
    /// Color code for transparent pixels.
    public static let transparent: UInt8 = 0x62

    /// Decodes `data` into one color code per pixel, row-major.
    /// - Parameter allBlank: special case for blank `style_white` background layers, where a 0xff
    ///   length means 0x400 instead of 0x4000 pixels.
    /// - Returns: the codes, the number of pixels the stream actually described, and the number of
    ///   bytes left over once the page was full.
    public static func decode(_ data: Data, width: Int, height: Int,
                              allBlank: Bool = false) -> (codes: [UInt8], decodedCount: Int, unreadBytes: Int) {
        let expected = width * height
        var codes = [UInt8](repeating: transparent, count: expected)
        var pos = 0
        var unread = 0

        codes.withUnsafeMutableBufferPointer { out in
            func emit(_ color: UInt8, _ length: Int) {
                let n = min(length, expected - pos)
                guard n > 0 else { return }
                if color != transparent {
                    (out.baseAddress! + pos).update(repeating: color, count: n)
                }
                pos += n
            }

            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let bytes = raw.bindMemory(to: UInt8.self)
                var held: (color: UInt8, length: UInt8)?
                var i = 0
                while i + 1 < bytes.count, pos < expected {
                    let color = bytes[i], length = bytes[i + 1]
                    i += 2

                    if let h = held {
                        held = nil
                        let heldRun = (Int(h.length & 0x7f) + 1) << 7
                        if color == h.color {
                            emit(color, 1 + Int(length) + heldRun)
                            continue
                        }
                        emit(h.color, heldRun)
                        // Falls through to process the current pair normally.
                    }

                    if length == 0xff {
                        emit(color, allBlank ? 0x400 : 0x4000)
                    } else if length & 0x80 != 0 {
                        held = (color, length)
                    } else {
                        emit(color, Int(length) + 1)
                    }
                }

                if let h = held {
                    // A trailing held run is as long as fits: ((len & 0x7f) + 1) << i for i in 7...0.
                    let remaining = expected - pos
                    for shift in stride(from: 7, through: 0, by: -1) {
                        let run = (Int(h.length & 0x7f) + 1) << shift
                        if run <= remaining {
                            emit(h.color, run)
                            break
                        }
                    }
                }
                unread = bytes.count - i
            }
        }
        return (codes, pos, unread)
    }

    /// Decodes `data` only if it is a well-formed layer: the stream describes exactly the page and
    /// nothing more. Every layer written by the device does; other data (an image mislabeled as
    /// RATTA_RLE, corruption) almost never does, and would otherwise render as stripes.
    /// The `allBlank` variant is tried as well if the first guess doesn't fit.
    public static func decodeValidated(_ data: Data, width: Int, height: Int, allBlank: Bool = false) -> [UInt8]? {
        for variant in [allBlank, !allBlank] {
            let result = decode(data, width: width, height: height, allBlank: variant)
            if result.decodedCount == width * height && result.unreadBytes == 0 { return result.codes }
        }
        return nil
    }
}
