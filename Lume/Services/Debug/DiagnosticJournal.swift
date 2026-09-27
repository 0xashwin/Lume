//
//  DiagnosticJournal.swift
//  Lume
//
//  An always-on, bounded, on-device log of what Lume's `Logger` categories
//  emit. It exists because the unified log can't back a support report on its
//  own (see Utils/Logger.swift): this file survives relaunches and crashes, so
//  a user who hits a problem can send it *afterwards* — without first having
//  had the foresight to turn logging on and reproduce.
//
//  Cost model: `record` formats nothing and touches no file — it appends to an
//  in-memory buffer under a lock. A utility-QoS queue drains the buffer to disk
//  every few seconds, immediately for warnings and worse (the process may be
//  about to die), and on backgrounding. Two files of `maxFileBytes` rotate, so
//  the journal can never grow past ~2 MB. Nothing here runs on the main
//  thread, which matters during playback (see the KSPlayer save-stall notes).
//
//  Privacy: the journal only ever receives `LumeLogMessage.redacted` text, and
//  it never leaves the device unless the user shares a diagnostic report.
//

import Foundation
import os

final nonisolated class DiagnosticJournal: @unchecked Sendable {
    static let shared = DiagnosticJournal(directory: DiagnosticJournal.defaultDirectory)

    static let maxFileBytes = 1024 * 1024
    private static let flushDelay: TimeInterval = 3
    private static let flushLineThreshold = 200

    let directory: URL?
    private let queue = DispatchQueue(label: "com.bilipp.lume.diagnostic-journal", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct Pending {
        let date: Date
        let level: DiagnosticLevel
        let category: String
        let message: String
    }

    private struct State {
        var pending: [Pending] = []
        var flushScheduled = false
        /// Collapses a message repeated back-to-back (a libvlc warning per
        /// packet, a retry loop) into one line plus a count, so a flood can't
        /// rotate the useful history out.
        var lastKey: String?
        var lastLevel = DiagnosticLevel.info
        var lastCategory = ""
        var repeats = 0

        /// Emits the pending repeat count, if any. Keeps `lastKey`, so a flood
        /// that spans a flush goes on collapsing instead of restarting.
        mutating func closeRepeatRun(at date: Date) {
            guard repeats > 0 else { return }
            pending.append(Pending(
                date: date, level: lastLevel, category: lastCategory,
                message: "↳ previous message repeated \(repeats) more time(s)"
            ))
            repeats = 0
        }
    }

    init(directory: URL?) {
        self.directory = directory
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            // Not inside `Diagnostics/`: MetricKit's archive prunes that
            // directory down to its newest payload files.
            .appendingPathComponent("DiagnosticJournal", isDirectory: true)
    }

    var currentFile: URL? {
        directory?.appendingPathComponent("journal.log")
    }

    var previousFile: URL? {
        directory?.appendingPathComponent("journal.1.log")
    }

    /// Debug-level entries are only kept while Detailed Logging is on; they are
    /// the chatty per-sample lines that would otherwise crowd out the history.
    func accepts(_ level: DiagnosticLevel) -> Bool {
        directory != nil && (level != .debug || DebugLogSettings.isEnabled)
    }

    // MARK: - Recording

    func record(level: DiagnosticLevel, category: String, message: String, date: Date = Date()) {
        let key = "\(category)|\(level.rawValue)|\(message)"
        let (scheduleFlush, flushNow) = state.withLock { state -> (Bool, Bool) in
            if key == state.lastKey {
                state.repeats += 1
                return (false, false)
            }
            state.closeRepeatRun(at: date)
            state.lastKey = key
            state.lastLevel = level
            state.lastCategory = category
            state.pending.append(Pending(date: date, level: level, category: category, message: message))
            let urgent = level.isProblem || state.pending.count >= Self.flushLineThreshold
            let schedule = !urgent && !state.flushScheduled
            if schedule { state.flushScheduled = true }
            return (schedule, urgent)
        }
        if flushNow {
            queue.async { self.drain() }
        } else if scheduleFlush {
            queue.asyncAfter(deadline: .now() + Self.flushDelay) { self.drain() }
        }
    }

    /// Writes everything buffered so far and returns once it's on disk. Called
    /// before reading the journal back and when the app leaves the foreground.
    func flush() {
        queue.sync { drain() }
    }

    // MARK: - Reading

    /// The journal as text, oldest first, across the rotated pair.
    func contents() -> String {
        flush()
        return queue.sync {
            [previousFile, currentFile].compactMap { url -> String? in
                guard let url, let data = FileManager.default.contents(atPath: url.path) else { return nil }
                return String(bytes: data, encoding: .utf8)
            }
            .joined()
        }
    }

    /// Deletes the journal — the privacy "forget" action on the Diagnostics screen.
    func clear() {
        flush()
        queue.sync {
            for url in [previousFile, currentFile].compactMap(\.self) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Writing (queue only)

    private func drain() {
        let batch = state.withLock { state -> [Pending] in
            state.flushScheduled = false
            // Close out a pending repeat run so a report taken mid-flood
            // shows the count instead of silently dropping it.
            state.closeRepeatRun(at: Date())
            defer { state.pending.removeAll(keepingCapacity: true) }
            return state.pending
        }
        guard !batch.isEmpty, let currentFile else { return }

        var text = ""
        for entry in batch {
            text += Self.format(entry.date, entry.level, entry.category, entry.message)
            text += "\n"
        }
        append(Data(text.utf8), to: currentFile)
    }

    private func append(_ data: Data, to file: URL) {
        let manager = FileManager.default
        prepareDirectory()
        rotateIfNeeded(file)
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func rotateIfNeeded(_ file: URL) {
        guard let previousFile,
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
              size >= Self.maxFileBytes
        else { return }
        try? FileManager.default.removeItem(at: previousFile)
        try? FileManager.default.moveItem(at: file, to: previousFile)
    }

    private func prepareDirectory() {
        guard var directory, !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    // MARK: - Line format

    /// `2026-09-27 14:03:11.482  [Network] error  message` — the same shape the
    /// old unified-log export used, so reports stay comparable.
    static func format(_ date: Date, _ level: DiagnosticLevel, _ category: String, _ message: String) -> String {
        "\(DiagnosticDateFormat.entry.string(from: date))  [\(category)] \(level.rawValue)  \(message)"
    }

    /// Parses a journal line back into its parts. Used by the report's
    /// "Recent problems" digest.
    static func parse(_ line: Substring) -> (date: Date, level: DiagnosticLevel, category: String, message: String)? {
        // "yyyy-MM-dd HH:mm:ss.SSS" is 23 characters.
        guard line.count > 27 else { return nil }
        let stampEnd = line.index(line.startIndex, offsetBy: 23)
        guard let date = DiagnosticDateFormat.entry.date(from: String(line[..<stampEnd])) else { return nil }
        let rest = line[stampEnd...].drop { $0 == " " }
        guard rest.first == "[", let close = rest.firstIndex(of: "]") else { return nil }
        let category = String(rest[rest.index(after: rest.startIndex) ..< close])
        let afterCategory = rest[rest.index(after: close)...].drop { $0 == " " }
        guard let space = afterCategory.firstIndex(of: " "),
              let level = DiagnosticLevel(rawValue: String(afterCategory[..<space]))
        else { return nil }
        let message = String(afterCategory[space...].drop { $0 == " " })
        return (date, level, category, message)
    }
}

/// Shared POSIX formatters. `DateFormatter` is thread-safe for formatting and
/// parsing on every supported OS.
nonisolated enum DiagnosticDateFormat {
    static let entry: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static let file: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
