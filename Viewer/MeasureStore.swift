import Foundation
import SupernoteKit

/// Persists calibrations and measurements per source file in Application Support.
@MainActor
enum MeasureStore {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.schaefer.SupernoteViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("measurements.json")
    }()

    private static var all: [String: MeasureState] = {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: MeasureState].self, from: data)) ?? [:]
    }()

    static func state(for source: URL) -> MeasureState {
        all[source.standardizedFileURL.path] ?? MeasureState()
    }

    static func save(_ state: MeasureState, for source: URL) {
        let key = source.standardizedFileURL.path
        if state.calibrations.isEmpty && state.measurements.isEmpty {
            all[key] = nil
        } else {
            all[key] = state
        }
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
