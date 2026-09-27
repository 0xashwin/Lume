//
//  DebugLogSettings.swift
//  Lume
//
//  Persisted state for the "Detailed Logging" switch on the Diagnostics
//  screen. Diagnostics are recorded regardless (see `DiagnosticJournal`); the
//  switch only admits the verbose `.debug` entries, which would otherwise
//  crowd the bounded journal. The key names predate that split and are kept so
//  an existing opt-in carries over.
//

import Foundation

nonisolated enum DebugLogSettings {
    /// Whether Detailed Logging is on.
    static let enabledKey = "debug.logging.enabled"
    /// `Date.timeIntervalSinceReferenceDate` of the moment logging was enabled,
    /// used to scope an export to the current debugging session.
    static let enabledSinceKey = "debug.logging.enabledSince"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// The instant logging was last enabled, or nil if it has never been on.
    static var enabledSince: Date? {
        let raw = UserDefaults.standard.double(forKey: enabledSinceKey)
        return raw > 0 ? Date(timeIntervalSinceReferenceDate: raw) : nil
    }

    /// Records the session start. Called when the toggle flips on so a later
    /// export can bound the entries it collects.
    static func markEnabled(at date: Date) {
        UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: enabledSinceKey)
    }
}
