//
//  DiagnosticSession.swift
//  Lume
//
//  Launch and lifecycle markers for the diagnostic journal, so a report reads
//  as a timeline of sessions rather than one undifferentiated wall of lines —
//  and says when the previous session didn't end on its own terms.
//
//  "Ended unexpectedly" is inferred, not observed: the flag below is set while
//  the app is in the foreground and cleared when it leaves. A process that dies
//  with the flag still set was killed in the foreground — a crash, a watchdog
//  termination (hang, 0xdead10cc), a jetsam while playing, or a debugger stop.
//  Swiping the app away from the switcher backgrounds it first, so it doesn't
//  trip the flag.
//

import Foundation
import OSLog
import SwiftUI
#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

nonisolated enum DiagnosticSession {
    static let inForegroundKey = "diagnostics.session.inForeground"
    static let launchCountKey = "diagnostics.session.launchCount"
    static let lastUnexpectedEndKey = "diagnostics.session.lastUnexpectedEnd"

    /// Set once per process, at launch.
    private(set) nonisolated(unsafe) static var startedAt = Date()
    private nonisolated(unsafe) static var observers: [NSObjectProtocol] = []

    /// The previous session's foreground death, if the last one ended that way.
    static var lastUnexpectedEnd: Date? {
        let raw = UserDefaults.standard.double(forKey: lastUnexpectedEndKey)
        return raw > 0 ? Date(timeIntervalSinceReferenceDate: raw) : nil
    }

    static var launchCount: Int {
        UserDefaults.standard.integer(forKey: launchCountKey)
    }

    /// Call once, as early in launch as possible.
    @MainActor
    static func start() {
        startedAt = Date()
        let defaults = UserDefaults.standard
        let launches = defaults.integer(forKey: launchCountKey) + 1
        defaults.set(launches, forKey: launchCountKey)

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        Logger.app.notice(
            "Session started — Lume \(SupportInfo.appVersion) (\(build)), \(DebugLogExporter.platformName) \(osVersion), \(DebugLogExporter.deviceModel), launch #\(launches)"
        )
        if defaults.bool(forKey: inForegroundKey) {
            defaults.set(Date().timeIntervalSinceReferenceDate, forKey: lastUnexpectedEndKey)
            Logger.app.error(
                "Previous session ended unexpectedly while in the foreground (crash, hang/watchdog kill, or out-of-memory)"
            )
        }
        defaults.set(true, forKey: inForegroundKey)

        let center = NotificationCenter.default
        #if canImport(UIKit)
            observers.append(center.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { _ in
                let footprint = DeviceDiagnostics.memoryFootprintMB.map { "\($0) MB" } ?? "unknown"
                Logger.memory.warning("System memory warning (footprint \(footprint))")
            })
            let terminate = UIApplication.willTerminateNotification
        #else
            // Quitting a Mac app never backgrounds its scene, so without this
            // every ⌘Q would read as a crash on the next launch.
            let terminate = NSApplication.willTerminateNotification
        #endif
        observers.append(center.addObserver(forName: terminate, object: nil, queue: nil) { _ in
            UserDefaults.standard.set(false, forKey: inForegroundKey)
            Logger.app.info("App terminating")
            DiagnosticJournal.shared.flush()
        })
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { _ in
            Logger.app.notice("Thermal state → \(DeviceDiagnostics.thermalStateName)")
        })
    }

    @MainActor
    static func scenePhaseChanged(to phase: ScenePhase) {
        let name = switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        Logger.app.info("Scene phase → \(name)")
        switch phase {
        case .active:
            UserDefaults.standard.set(true, forKey: inForegroundKey)
        case .background:
            UserDefaults.standard.set(false, forKey: inForegroundKey)
            // The process may be suspended (or killed) from here on without
            // another chance to write.
            DiagnosticJournal.shared.flush()
        default:
            break
        }
    }
}
