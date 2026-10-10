import CoreGraphics
import Foundation

/// Parsing and formatting of real-world lengths.
public enum Length {
    /// Parses a length such as "2,23 m", "2.23", "223 cm" or "2230mm" into meters.
    /// Meters are assumed when no unit is given; both comma and dot work as decimal separator.
    public static func parse(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var factor = 1.0
        for (suffix, unitFactor) in [("mm", 0.001), ("cm", 0.01), ("m", 1.0)] where s.hasSuffix(suffix) {
            factor = unitFactor
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        s = s.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(s), value.isFinite, value > 0 else { return nil }
        return value * factor
    }

    /// Formats meters for display: "3,47 m" (de) / "3.47 m" (en); centimeters below 1 m.
    public static func format(_ meters: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        if meters < 1 {
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            return (formatter.string(from: NSNumber(value: meters * 100)) ?? "\(meters * 100)") + " cm"
        }
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: meters)) ?? "\(meters)") + " m"
    }
}

/// A reference line of known real length on a PDF page.
public struct Calibration: Codable, Equatable {
    public var id = UUID()
    public var pageIndex: Int
    public var start: CGPoint
    public var end: CGPoint
    public var meters: Double

    public init(pageIndex: Int, start: CGPoint, end: CGPoint, meters: Double) {
        self.pageIndex = pageIndex
        self.start = start
        self.end = end
        self.meters = meters
    }

    public var pagePoints: Double { distance(start, end) }
    public var metersPerPoint: Double { pagePoints > 0 ? meters / pagePoints : 0 }
}

/// A measured line on a PDF page, in page coordinates (PDF points).
public struct MeasureLine: Codable, Equatable {
    public var id = UUID()
    public var pageIndex: Int
    public var start: CGPoint
    public var end: CGPoint

    public init(pageIndex: Int, start: CGPoint, end: CGPoint) {
        self.pageIndex = pageIndex
        self.start = start
        self.end = end
    }

    public var pagePoints: Double { distance(start, end) }
}

/// Calibrations and measurements for one document.
public struct MeasureState: Codable, Equatable {
    /// At most one calibration per page.
    public var calibrations: [Calibration] = []
    public var measurements: [MeasureLine] = []
    /// Page of the most recent calibration, used for pages without their own.
    public var lastCalibratedPage: Int?

    public init() {}

    public mutating func calibrate(_ calibration: Calibration) {
        calibrations.removeAll { $0.pageIndex == calibration.pageIndex }
        calibrations.append(calibration)
        lastCalibratedPage = calibration.pageIndex
    }

    public mutating func remove(id: UUID) {
        measurements.removeAll { $0.id == id }
        calibrations.removeAll { $0.id == id }
        if let last = lastCalibratedPage, !calibrations.contains(where: { $0.pageIndex == last }) {
            lastCalibratedPage = calibrations.last?.pageIndex
        }
    }

    /// The scale for a page: its own calibration, otherwise the most recent one.
    public func scale(forPage pageIndex: Int) -> (metersPerPoint: Double, fromPage: Int)? {
        if let own = calibrations.first(where: { $0.pageIndex == pageIndex }) {
            return (own.metersPerPoint, pageIndex)
        }
        if let last = lastCalibratedPage, let other = calibrations.first(where: { $0.pageIndex == last }) {
            return (other.metersPerPoint, last)
        }
        return nil
    }

    /// Real length of a measurement in meters, or nil when no calibration exists yet.
    public func meters(of line: MeasureLine) -> Double? {
        scale(forPage: line.pageIndex).map { line.pagePoints * $0.metersPerPoint }
    }
}

public func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    Double(hypot(b.x - a.x, b.y - a.y))
}
