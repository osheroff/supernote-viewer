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

    public var isEraser: Bool { color == 255 }
    public var isMarker: Bool { penType == 11 || [0x66, 0x67, 0x68, 0x9e, 0xca].contains(color) }
    /// Whether this stroke contributes visible ink.
    public var isInk: Bool { !isDeleted && !isEraser && !path.isEmpty }

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
    /// - 212: u32 n, n × (u32, u32) raw samples
    /// - u32 + u16[] pressure, u32 + u32[] tilt, u32 + u8[] flags
    /// - 60 bytes (status i32 at +8; −4 = erased), u32 k + i32[k] eraser targets, 10 bytes
    /// - u32 contour count, each u32 m + m × (f32 x, f32 y)
    static func parse(_ data: Data) throws -> SNStroke {
        var r = ByteReader(data)
        let penType = Int(try r.u32())
        let color = Int(try r.u32())
        let width = Int(try r.u32())
        r.offset = 44
        let layer = Int(try r.u32())

        r.offset = 212
        let samples = Int(try r.u32())
        try r.skip(samples * 8)
        try r.skip(Int(try r.u32()) * 2)  // pressure
        try r.skip(Int(try r.u32()) * 4)  // tilt
        try r.skip(Int(try r.u32()))      // per-sample flags

        let base = r.offset
        r.offset = base + 8
        let status = try r.i32()
        r.offset = base + 60
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

        return SNStroke(penType: penType, color: color, width: width, layer: layer,
                        isDeleted: status != 0, path: path)
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

extension SNPage {
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
