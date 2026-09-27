//
//  DiagnosticsTests.swift
//  LumeTests
//
//  Guards the diagnostic pipeline end to end: what a log call puts in the
//  journal (and what it must keep out), how the journal persists and reads
//  back, and that the report's network descriptions never carry a host,
//  path or credential.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Log message privacy

struct LumeLogMessagePrivacyTests {
    private func redacted(_ message: LumeLogMessage) -> String {
        message.redacted
    }

    @Test func `public strings are kept but URLs are scrubbed`() {
        let url = "http://iptv.example.com/live/alice/s3cret/1.ts"
        let text = redacted("open \(url, privacy: .public) failed")
        #expect(text == "open http://<redacted> failed")
    }

    @Test func `default privacy strings are scrubbed too`() {
        let url = "https://host.tld/get.php?username=alice&password=s3cret"
        #expect(redacted("GET \(url)") == "GET https://<redacted>")
    }

    @Test func `private values never reach the journal`() {
        let mac = "00:1A:79:12:34:56"
        #expect(redacted("mac=\(mac, privacy: .private)") == "mac=<private>")
    }

    @Test func `hash masked values are stable and opaque`() {
        let url = "http://host/stream.m3u8"
        let first = redacted("url=\(url, privacy: .private(mask: .hash))")
        let second = redacted("url=\(url, privacy: .private(mask: .hash))")
        #expect(first == second)
        #expect(first.hasPrefix("url=<hash:"))
        #expect(!first.contains("host"))
    }

    @Test func `numbers flags and fixed precision floats render`() {
        let seconds = 1.23456
        #expect(redacted("n=\(42) ok=\(true) t=\(seconds, format: .fixed(precision: 2))s") == "n=42 ok=true t=1.23s")
    }

    @Test func `errors render as a credential free chain`() {
        let underlying = URLError(.secureConnectionFailed, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "https://host/get.php?password=s3cret",
            NSLocalizedDescriptionKey: "TLS failed for https://host/get.php?password=s3cret"
        ])
        let error: Error = XtreamError.networkError(underlying)
        let text = redacted("failed — \(error)")
        #expect(text.contains("XtreamError: network error"))
        #expect(text.contains("← NSURLErrorDomain -1200"))
        #expect(!text.contains("s3cret"))
    }
}

// MARK: - Error descriptions

struct LogRedactionChainTests {
    private struct Payload: Decodable {
        let name: String
    }

    @Test func `decoding errors name the path, never the value`() throws {
        let json = Data(#"{"name": 12345}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Payload.self, from: json)
            Issue.record("expected a decoding failure")
        } catch {
            let text = LogRedaction.describe(error)
            #expect(text.hasPrefix("DecodingError: type mismatch"))
            #expect(text.contains("at name"))
            #expect(!text.contains("12345"))
        }
    }

    @Test func `stable hash is deterministic`() {
        #expect(LogRedaction.stableHash("abc") == LogRedaction.stableHash("abc"))
        #expect(LogRedaction.stableHash("abc") != LogRedaction.stableHash("abd"))
        #expect(LogRedaction.stableHash("abc").count == 8)
    }
}

// MARK: - Journal

@Suite(.serialized)
struct DiagnosticJournalTests {
    private func makeJournal() -> (DiagnosticJournal, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-tests-\(UUID().uuidString)", isDirectory: true)
        return (DiagnosticJournal(directory: directory), directory)
    }

    @Test func `recorded lines persist and read back in order`() {
        let (journal, directory) = makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        journal.record(level: .info, category: "Network", message: "first")
        journal.record(level: .error, category: "Network", message: "second")
        let lines = journal.contents().split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("[Network] info  first"))
        #expect(lines[1].hasSuffix("[Network] error  second"))
    }

    @Test func `survives a new journal instance on the same directory`() {
        let (journal, directory) = makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        journal.record(level: .notice, category: "App", message: "before relaunch")
        journal.flush()
        let relaunched = DiagnosticJournal(directory: directory)
        #expect(relaunched.contents().contains("before relaunch"))
    }

    @Test func `back to back repeats collapse into a count`() {
        let (journal, directory) = makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0 ..< 5 {
            journal.record(level: .warning, category: "Player", message: "late frame")
        }
        journal.record(level: .info, category: "Player", message: "recovered")
        let text = journal.contents()
        #expect(text.components(separatedBy: "late frame").count == 2)
        // Warnings flush immediately, so the run may be counted in pieces.
        let repeated = text.matches(of: /repeated (\d+) more/).compactMap { Int($0.output.1) }.reduce(0, +)
        #expect(repeated == 4)
        #expect(text.contains("recovered"))
    }

    @Test func `clear removes everything`() {
        let (journal, directory) = makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        journal.record(level: .error, category: "App", message: "gone soon")
        journal.clear()
        #expect(journal.contents().isEmpty)
    }

    @Test func `lines parse back into their parts`() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let line = DiagnosticJournal.format(date, .error, "Network", "Xtream auth rejected: HTTP 403")
        let parsed = DiagnosticJournal.parse(Substring(line))
        #expect(parsed?.level == .error)
        #expect(parsed?.category == "Network")
        #expect(parsed?.message == "Xtream auth rejected: HTTP 403")
        #expect(abs((parsed?.date ?? .distantPast).timeIntervalSince(date)) < 0.001)
    }

    @Test func `the journal rotates instead of growing without bound`() {
        let (journal, directory) = makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = String(repeating: "x", count: 4096)
        for index in 0 ..< 600 {
            journal.record(level: .info, category: "Test", message: "\(index) \(chunk)")
            if index % 100 == 0 { journal.flush() }
        }
        journal.flush()
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: journal.previousFile?.path ?? ""))
        let size = (try? manager.attributesOfItem(atPath: journal.currentFile?.path ?? ""))?[.size] as? Int ?? 0
        #expect(size < DiagnosticJournal.maxFileBytes * 2)
    }
}

// MARK: - Network descriptions

struct NetworkDiagnosticsTests {
    @Test func `shape never carries the host path or credentials`() {
        let shape = NetworkDiagnostics.shape(of: "http://iptv.example.com:8080/get.php?username=alice&password=s3cret&type=m3u_plus")
        #expect(shape.contains("http"))
        #expect(shape.contains("domain"))
        #expect(shape.contains("port 8080"))
        #expect(shape.contains("ending .php"))
        #expect(!shape.contains("example"))
        #expect(!shape.contains("alice"))
        #expect(!shape.contains("s3cret"))
    }

    @Test func `shape classifies host kinds`() {
        #expect(NetworkDiagnostics.hostKind("192.168.1.10") == "LAN IPv4")
        #expect(NetworkDiagnostics.hostKind("8.8.8.8") == "public IPv4")
        #expect(NetworkDiagnostics.hostKind("nas.local") == "mDNS (.local) host")
        #expect(NetworkDiagnostics.hostKind("localhost") == "localhost")
        #expect(NetworkDiagnostics.shape(of: "example.com:8080").hasPrefix("no scheme") || NetworkDiagnostics.shape(of: "example.com:8080").contains("no host"))
    }

    @Test func `html bodies are named by their title`() {
        let html = Data("<!DOCTYPE html><html><head><title>Just a moment...</title></head><body>cf-chl</body></html>".utf8)
        #expect(NetworkDiagnostics.bodyKind(html) == "HTML page \"Just a moment...\" (Cloudflare)")
    }

    @Test func `json bodies contribute key names only`() {
        let json = Data(#"{"user_info": {"password": "s3cret"}, "server_info": {}}"#.utf8)
        let kind = NetworkDiagnostics.bodyKind(json)
        #expect(kind == "JSON object {server_info, user_info}")
        #expect(!kind.contains("s3cret"))
    }

    @Test func `short text refusals are quoted`() {
        #expect(NetworkDiagnostics.bodyKind(Data("Authorization failed.".utf8)) == "text \"Authorization failed.\"")
        #expect(NetworkDiagnostics.bodyKind(Data()) == "empty body")
        #expect(NetworkDiagnostics.bodyKind(Data("#EXTM3U\n#EXTINF:-1,A".utf8)) == "m3u playlist")
    }

    @Test func `fingerprint carries status and content type`() throws {
        let url = try #require(URL(string: "https://host.example/player_api.php"))
        let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [
            "Content-Type": "text/html; charset=utf-8", "Server": "cloudflare"
        ])
        let fingerprint = NetworkDiagnostics.fingerprint(response: response, data: Data("<html><title>Blocked</title></html>".utf8))
        #expect(fingerprint.hasPrefix("HTTP 403 · text/html · server cloudflare"))
        #expect(fingerprint.contains("HTML page \"Blocked\""))
        #expect(!fingerprint.contains("host.example"))
    }
}

// MARK: - Report

struct DiagnosticReportTests {
    private func line(_ minutesAgo: Double, _ level: DiagnosticLevel, _ message: String, now: Date) -> String {
        DiagnosticJournal.format(now.addingTimeInterval(-minutesAgo * 60), level, "Network", message)
    }

    @Test func `problem digest dedupes numbered variants and drops info`() {
        let now = Date()
        let journal = [
            line(30, .warning, "Xtream auth failed; retry 1/2 after 2.0s", now: now),
            line(20, .warning, "Xtream auth failed; retry 2/2 after 4.0s", now: now),
            line(10, .info, "Xtream auth payload 120 bytes", now: now),
            line(5, .error, "Xtream auth request failed permanently", now: now)
        ].joined(separator: "\n")
        let digest = DebugLogExporter.problemDigest(journal, now: now)
        #expect(digest.count == 2)
        #expect(digest[0].contains("failed permanently"))
        #expect(digest[1].contains("×2"))
        #expect(!digest.joined().contains("payload"))
    }

    @Test func `problem digest ignores entries older than a week`() {
        let now = Date()
        let journal = line(8 * 24 * 60, .error, "ancient", now: now)
        #expect(DebugLogExporter.problemDigest(journal, now: now).isEmpty)
    }

    @MainActor
    @Test func `playlist summary never names the playlist or its account`() throws {
        let container = try makeTestContainer()
        let playlist = Playlist(name: "Secret Provider", serverURL: "http://secret-host.example:8080", username: "alice", password: "s3cret")
        playlist.expDate = "1"
        container.mainContext.insert(playlist)
        try container.mainContext.save()

        let text = DebugLogExporter.catalogLines(container: container, now: Date()).joined(separator: "\n")
        #expect(text.contains("#1 xtream"))
        #expect(text.contains("EXPIRED"))
        #expect(text.contains("port 8080"))
        for secret in ["Secret Provider", "secret-host", "alice", "s3cret"] {
            #expect(!text.contains(secret))
        }
    }

    @Test func `compact summary respects its length cap`() {
        let exporter = DebugLogExporter(
            metadata: .init(
                appVersion: "9.9", buildNumber: "1", platform: "tvOS", osVersion: "26.4",
                deviceModel: "AppleTV14,1", engineSummary: "KSPlayer"
            ),
            journal: DiagnosticJournal(directory: nil)
        )
        let summary = exporter.compactSummary(maxLength: 120)
        #expect(summary.count <= 120)
        #expect(summary.hasPrefix("Lume 9.9 (1)"))
    }

    @Test func `mailto link encodes the body`() {
        let link = DiagnosticsReport.mailtoLink(summary: "a & b = c\nline", appVersion: "1.0")
        #expect(link.hasPrefix("mailto:\(SupportInfo.email)?subject="))
        #expect(link.contains("&body=a%20%26%20b%20%3D%20c%0Aline"))
    }
}
