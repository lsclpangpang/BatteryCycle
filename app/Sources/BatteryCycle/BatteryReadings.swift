import Foundation

enum BatteryReadings {
    static func capacityPercent(current: Int, maximum: Int) -> Int? {
        guard maximum > 0, current >= 0, current <= maximum else { return nil }
        // Multiplying the raw integer first can overflow on malformed readings.
        return Int(exactly: (Double(current) * 100 / Double(maximum)).rounded(.down))
    }

    static func healthPercent(full: Int, design: Int) -> Int? {
        guard design > 0, full >= 0 else { return nil }
        return Int(exactly: (Double(full) * 100 / Double(design)).rounded())
    }

    static func elapsedSeconds(since updated: TimeInterval, now: TimeInterval) -> Int? {
        guard updated.isFinite, now.isFinite, updated > 0, updated <= now else { return nil }
        return Int(exactly: (now - updated).rounded(.down))
    }

    static func readSmallFile(at url: URL) throws -> Data {
        // Status/configuration files are small. Bound allocation even if a
        // damaged/replaced file is unexpectedly large or keeps growing.
        let maximumBytes = 64 * 1_024
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}
