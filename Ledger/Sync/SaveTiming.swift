import Foundation
import os

/// Only phase names, elapsed time and operation counts; never ledger text or account identifiers.
struct SaveTiming {
    private let start = ProcessInfo.processInfo.systemUptime
    private static let logger = Logger(subsystem: "com.iskerwin.ledger", category: "save-timing")

    func record(_ phase: String, count: Int = 0) {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        Self.logger.info("phase=\(phase, privacy: .public) elapsed_ms=\(ms, privacy: .public) count=\(count, privacy: .public)")
    }

    func recordIfSlow(_ phase: String, count: Int = 0) {
        if ProcessInfo.processInfo.systemUptime - start >= 0.005 { record(phase, count: count) }
    }
}
