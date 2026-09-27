//
//  LoginView+Diagnostics.swift
//  Lume
//
//  Journal markers for the add-playlist connection test. Before these, a
//  failed add left nothing behind but the red text on screen: the view caught
//  the error, showed it, and logged nothing — so the one flow that most needs
//  a report produced an empty one.
//
//  Each attempt logs the source kind and the address *shape* (never the
//  address), and each outcome its duration and the full, credential-free
//  error chain.
//

import OSLog
import SwiftUI

extension LoginView {
    /// The report's "Reported from" line.
    var diagnosticsOrigin: String {
        "Add Playlist (\(sourceType.rawValue))"
    }

    func noteAddAttempt(_ source: String, address: String) {
        AddPlaylistAttemptClock.startedAt = .now
        let shape = NetworkDiagnostics.shape(of: address)
        Logger.app.notice("Add playlist: testing \(source) connection [\(shape)]")
    }

    func noteAddFailure(_ error: Error) {
        let elapsed = AddPlaylistAttemptClock.elapsedDescription
        let timedOut = error is ConnectionTimeoutError
        Logger.app.error(
            "Add playlist failed after \(elapsed)\(timedOut ? " (connection-test deadline)" : "") — \(error)"
        )
    }

    func noteAddSuccess(_ playlist: Playlist) {
        let elapsed = AddPlaylistAttemptClock.elapsedDescription
        Logger.app.notice("Add playlist: \(playlist.sourceType.rawValue) added after \(elapsed)")
    }
}

/// When the running connection test began. One at a time: the form disables
/// Add while a test is in flight.
@MainActor
enum AddPlaylistAttemptClock {
    static var startedAt: ContinuousClock.Instant?

    static var elapsedDescription: String {
        guard let startedAt else { return "an unknown time" }
        let elapsed = (ContinuousClock.now - startedAt).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return String(format: "%.1fs", seconds)
    }
}
