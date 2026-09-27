//
//  DeviceDiagnostics.swift
//  Lume
//
//  Point-in-time device facts for a diagnostic report: where the build came
//  from, locale, storage, memory, power and the network path. Each one has
//  closed a support thread at least once ("full disk", "Low Data Mode",
//  "no IPv4 route", "it's a TestFlight build").
//

import Foundation
import Network
import os

nonisolated enum DeviceDiagnostics {
    /// App Store, TestFlight, sideload or a local debug build — the first thing
    /// to know when a user reports something already fixed.
    static var installSource: String {
        #if DEBUG
            return "Debug build"
        #elseif SIDE_LOAD
            return "Sideload"
        #else
            #if os(macOS)
                return "App Store"
            #else
                let receipt = Bundle.main.appStoreReceiptURL?.lastPathComponent
                return receipt == "sandboxReceipt" ? "TestFlight" : "App Store"
            #endif
        #endif
    }

    static var localeSummary: String {
        let languages = Locale.preferredLanguages.prefix(3).joined(separator: ", ")
        return "\(Locale.current.identifier) · languages \(languages) · time zone \(TimeZone.current.identifier)"
    }

    static var freeDiskDescription: String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #if os(tvOS)
            // tvOS has no "important usage" figure; the plain one is what it offers.
            let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
            guard let free = values?.volumeAvailableCapacity.map(Int64.init) else { return "unknown" }
        #else
            let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            guard let free = values?.volumeAvailableCapacityForImportantUsage else { return "unknown" }
        #endif
        let total = values?.volumeTotalCapacity.map { Int64($0) } ?? 0
        return "\(byteString(free)) free of \(byteString(total))"
    }

    static var memoryDescription: String {
        let physical = byteString(Int64(ProcessInfo.processInfo.physicalMemory))
        let footprint = memoryFootprintMB.map { "\($0) MB" } ?? "unknown"
        return "\(physical) physical · app footprint \(footprint)"
    }

    /// The app's physical footprint — the figure jetsam judges it by.
    static var memoryFootprintMB: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    static var thermalStateName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static var powerDescription: String {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
        return "thermal \(thermalStateName) · Low Power Mode \(lowPower)"
    }

    static func uptimeDescription(since start: Date, now: Date = Date()) -> String {
        durationString(now.timeIntervalSince(start))
    }

    static func durationString(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        if seconds < 86400 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 86400)d \(seconds % 86400 / 3600)h"
    }

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Network path

    /// The current network path, read once. `NWPathMonitor` reports its first
    /// path almost immediately; the timeout only guards a monitor that never
    /// calls back (seen on a sim with networking disabled).
    static func networkPathDescription(timeout: Duration = .seconds(1)) async -> String {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.bilipp.lume.diagnostics.path")
        let path: NWPath? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (NWPath?) -> Void = { path in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: path) }
            }
            monitor.pathUpdateHandler = { finish($0) }
            monitor.start(queue: queue)
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
        monitor.cancel()
        guard let path else { return "unknown (no path update)" }
        return describe(path)
    }

    static func describe(_ path: NWPath) -> String {
        var parts = [statusName(path.status)]
        let interfaces: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "Wi-Fi"), (.wiredEthernet, "Ethernet"), (.cellular, "cellular"),
            (.loopback, "loopback"), (.other, "other/VPN")
        ]
        let using = interfaces.filter { path.usesInterfaceType($0.0) }.map(\.1)
        if !using.isEmpty { parts.append("via \(using.joined(separator: "+"))") }
        let routes = [path.supportsIPv4 ? "IPv4" : nil, path.supportsIPv6 ? "IPv6" : nil].compactMap(\.self)
        parts.append(routes.isEmpty ? "no IP route" : routes.joined(separator: "/"))
        let flags: [(Bool, String)] = [
            (!path.supportsDNS, "NO DNS"), (path.isExpensive, "expensive"), (path.isConstrained, "Low Data Mode")
        ]
        parts += flags.filter(\.0).map(\.1)
        if path.status == .unsatisfied {
            parts.append("(\(unsatisfiedReasonName(path.unsatisfiedReason)))")
        }
        return parts.joined(separator: " · ")
    }

    private static func statusName(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: "online"
        case .unsatisfied: "OFFLINE"
        case .requiresConnection: "requires connection"
        @unknown default: "unknown"
        }
    }

    private static func unsatisfiedReasonName(_ reason: NWPath.UnsatisfiedReason) -> String {
        switch reason {
        case .notAvailable: "no network"
        case .cellularDenied: "cellular denied for this app"
        case .wifiDenied: "Wi-Fi denied for this app"
        case .localNetworkDenied: "local network access denied"
        case .vpnInactive: "VPN inactive"
        @unknown default: "unknown reason"
        }
    }
}
