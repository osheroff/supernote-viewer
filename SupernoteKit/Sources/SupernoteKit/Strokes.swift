import CoreGraphics
import Foundation

/// A handwritten stroke from a page's TOTALPATH block.
///
/// Besides the raw pen samples, every record carries the device's own rendered outline of the
/// stroke (already accounting for pen width and pressure) as polygons in page pixels. Filling those
/// polygons reproduces the device bitmap exactly, so they are all we need for vector output.
public struct SNStroke {
    public let penType: Int
    public let color: Int
    public let width: Int
    /// 0 = MAINLAYER, 1…3 = LAYER1…3.
    public let layer: Int
    /// Strokes that were (partially) erased stay in the file with this flag; the surviving parts
    /// are stored as separate outline-only fragment strokes.
    public let isDeleted: Bool
    /// Outline polygons in page pixel coordinates (origin top-left, y down). Fill with even-odd.
    public let path: CGPath
    /// Set for typed text boxes, whose "outline" is just their frame; the glyphs are only in the bitmap.
    public let textBox: SNTextBox?

    public var isEraser: Bool { color == 255 }
    public var isMarker: Bool { penType == 11 || [0x66, 0x67, 0x68, 0x9e, 0xca].contains(color) }
    /// Whether this stroke contributes visible ink. Pen type 0 is not a pen (text boxes).
    public var isInk: Bool { !isDeleted && !isEraser && penType != 0 && !path.isEmpty }

    public static func layerIndex(forLayerName name: String) -> Int? {
        switch name {
        case "MAINLAYER": return 0
        case "LAYER1": return 1
        case "LAYER2": return 2
        case "LAYER3": return 3
        default: return nil
        }
    }

    /// Parses a TOTALPATH block: u32 count, then `count` records of (u32 size, bytes).
    static func parseAll(_ data: Data) throws -> [SNStroke] {
        var r = ByteReader(data)
        let count = Int(try r.u32())
        var strokes: [SNStroke] = []
        strokes.reserveCapacity(count)
        for _ in 0..<count {
            let size = Int(try r.u32())
            strokes.append(try parse(try r.bytes(size)))
        }
        return strokes
    }

    /// Record layout (little-endian):
    /// - 0: u32 pen type, 4: u32 color, 8: u32 width, 44: u32 layer, 48: name, 124: coordinate space
    /// - 208: u32 + 24-byte disable areas (usually none)
    /// - u32 n, n × (u32, u32) raw samples
    /// - u32 + u16[] pressure, u32 + u32[] tilt, u32 + u8[] flags, u32 + 8-byte[] and u32 + i32[] epa data
    /// - 52 bytes (status i32 at +0; nonzero = erased), u32 k + i32[k] eraser targets, 10 bytes
    /// - u32 contour count, each u32 m + m × (f32 x, f32 y)
    /// - text boxes (pen type 0) continue with a block holding u32 length + comma-separated base64
    ///   fields: [4] frame "x,y,w,h", [10] font size, [11] font path, [12] text
    ///
    /// The optional lists are mapped in supernote-typescript's `plans/vector-format-spec.md`.
    static func parse(_ data: Data) throws -> SNStroke {
        var r = ByteReader(data)
        let penType = Int(try r.u32())
        let color = Int(try r.u32())
        let width = Int(try r.u32())
        r.offset = 44
        let layer = Int(try r.u32())

        r.offset = 208
        try r.skip(Int(try r.u32()) * 24)  // disable areas
        let samples = Int(try r.u32())
        try r.skip(samples * 8)
        try r.skip(Int(try r.u32()) * 2)  // pressure
        try r.skip(Int(try r.u32()) * 4)  // tilt
        try r.skip(Int(try r.u32()))      // per-sample flags
        try r.skip(Int(try r.u32()) * 8)  // epa points
        try r.skip(Int(try r.u32()) * 4)  // epa grays

        let base = r.offset
        let status = try r.i32()
        r.offset = base + 52
        let erasedCount = Int(try r.u32())
        try r.skip(erasedCount * 4 + 10)

        let contourCount = Int(try r.u32())
        guard contourCount < 100_000 else { throw SNError.malformed("stroke contour count \(contourCount)") }
        let path = CGMutablePath()
        for _ in 0..<contourCount {
            let m = Int(try r.u32())
            guard m <= (data.count - r.offset) / 8 else { throw SNError.outOfBounds("stroke contour") }
            var points: [CGPoint] = []
            points.reserveCapacity(m)
            for _ in 0..<m {
                let x = try r.f32(), y = try r.f32()
                points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
            addSmoothContour(points, to: path)
        }

        let textBox = penType == 0 ? SNTextBox.parse(r.data[r.offset...]) : nil
        return SNStroke(penType: penType, color: color, width: width, layer: layer,
                        isDeleted: status != 0, path: path, textBox: textBox)
    }

    /// The device outlines are polygons on a quarter-pixel grid, which look faceted when zoomed in.
    /// Curving through segment midpoints (with the vertices as control points) smooths them while
    /// moving the edge by less than half a device pixel.
    private static func addSmoothContour(_ points: [CGPoint], to path: CGMutablePath) {
        guard points.count >= 3 else { return }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[points.count - 1], points[0]))
        for i in 0..<points.count {
            path.addQuadCurve(to: mid(points[i], points[(i + 1) % points.count]), control: points[i])
        }
        path.closeSubpath()
    }
}

/// A typed text box. The device renders its text into the layer bitmap.
public struct SNTextBox {
    /// Frame in page pixel coordinates (origin top-left, y down).
    public let rect: CGRect
    public let text: String
    /// Font size in page pixels.
    public let fontSize: Double

    /// Finds the u32-length-prefixed list of base64 fields in a text box record's tail.
    /// Best effort: nil if no such list is found or its fields don't parse.
    static func parse(_ tail: Data) -> SNTextBox? {
        let bytes = [UInt8](tail)
        func isFieldByte(_ b: UInt8) -> Bool {
            (0x41...0x5a).contains(b) || (0x61...0x7a).contains(b) || (0x30...0x39).contains(b)
                || b == 0x2b || b == 0x2f || b == 0x3d || b == 0x2c
        }
        var i = 0
        while i + 4 <= bytes.count {
            let length = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
            let start = i + 4
            if length >= 16, start + length <= bytes.count, bytes[start..<start + length].allSatisfy(isFieldByte) {
                let fields = String(decoding: bytes[start..<start + length], as: UTF8.self)
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { Data(base64Encoded: String($0)).map { String(decoding: $0, as: UTF8.self) } }
                guard fields.count > 12, let frame = fields[4], let size = fields[10].flatMap(Double.init),
                      let text = fields[12] else { return nil }
                let n = frame.split(separator: ",").compactMap { Double($0) }
                guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
                return SNTextBox(rect: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), text: text, fontSize: size)
            }
            i += 1
        }
        return nil
    }
}

extension SNPage {
    /// Typed text boxes on the page (from its strokes), excluding deleted ones. Heading, link and
    /// star frames are stored like text boxes but with the text "none"; those are left out.
    public func textBoxes(in file: SNFile) -> [SNTextBox] {
        (strokes(in: file) ?? []).filter { !$0.isDeleted }.compactMap(\.textBox).filter { $0.text != "none" }
    }

    /// The page's strokes, or nil if the page has no TOTALPATH or it can't be parsed.
    public func strokes(in file: SNFile) -> [SNStroke]? {
        guard let address = metadata.address("TOTALPATH"),
              let block = try? file.block(at: address) else { return nil }
        return try? SNStroke.parseAll(block)
    }
}

/// Bounds-checked little-endian reader.
struct ByteReader {
    let data: Data
    var offset = 0

    init(_ data: Data) {
        self.data = data.startIndex == 0 ? data : Data(data)
    }

    private mutating func load<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= data.count else {
            throw SNError.outOfBounds("read at \(offset)")
        }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size
        return T(littleEndian: value)
    }

    mutating func u32() throws -> UInt32 { try load(UInt32.self) }
    mutating func i32() throws -> Int32 { try load(Int32.self) }
    mutating func f32() throws -> Float { Float(bitPattern: try load(UInt32.self)) }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else { throw SNError.outOfBounds("skip at \(offset)") }
        offset += count
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw SNError.outOfBounds("bytes at \(offset)") }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
}
