//
//  NetworkDiagnostics.swift
//  Lume
//
//  Credential-free descriptions of *what* a request went to and *what* came
//  back, for the cases a status code can't explain.
//
//  An address is described by its shape — scheme, host kind, port, path kind —
//  never its host or path: a provider's hostname and the credentials in its
//  path are exactly what a report must not carry, yet "http on :8080 to a LAN
//  IP" versus "https to a domain" settles most add-playlist failures (ATS,
//  local-network permission, a typo'd scheme).
//
//  A response is described by its fingerprint: status, content type, size and
//  the *kind* of body. A 200 that decodes to nothing is almost always an HTML
//  page — a Cloudflare challenge, a provider's "account expired" page, a
//  captive portal — and its <title> names which one. JSON bodies contribute
//  their top-level key names only: Xtream's auth response echoes the password.
//

import Foundation

nonisolated enum NetworkDiagnostics {
    // MARK: - Address shape

    /// e.g. `http · domain · port 8080 · path /player_api.php-style (1 segment) · 2 query items`.
    static func shape(of string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme else {
            return trimmed.contains("://") ? "unparseable URL" : "no scheme (e.g. missing http://)"
        }
        if scheme == "file" { return "local file" }

        var parts = [scheme.lowercased()]
        parts.append(hostKind(components.host))
        if let port = components.port { parts.append("port \(port)") }
        if components.user != nil || components.password != nil { parts.append("userinfo") }

        let segments = components.path.split(separator: "/")
        if segments.isEmpty {
            parts.append("no path")
        } else {
            // The last segment's extension alone (".m3u", ".php") — never the
            // name, which for Xtream stream links is the account password.
            let ext = segments.last.map { ($0 as NSString).pathExtension } ?? ""
            let kind = ext.isEmpty ? "" : " ending .\(ext.lowercased())"
            parts.append("path \(segments.count) segment(s)\(kind)")
            if segments.first?.lowercased() == "c" || components.path.lowercased().contains("/stalker_portal") {
                parts.append("portal-style path")
            }
        }
        if let items = components.queryItems, !items.isEmpty {
            // Parameter *names* only; values carry credentials.
            let names = items.map { $0.name.lowercased() }.filter { safeQueryNames.contains($0) }
            let named = names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"
            parts.append("\(items.count) query item(s)\(named)")
        }
        if trimmed != string { parts.append("had surrounding whitespace") }
        return parts.joined(separator: " · ")
    }

    private static let safeQueryNames: Set<String> = ["username", "password", "type", "output", "action", "mac"]

    static func hostKind(_ host: String?) -> String {
        guard let host = host?.lowercased(), !host.isEmpty else { return "no host" }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return "localhost" }
        if host.hasSuffix(".local") { return "mDNS (.local) host" }
        if host.contains(":") { return "IPv6 literal" }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, host.split(separator: ".").count == 4 {
            let isPrivate = octets[0] == 10
                || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 100 && (64 ... 127).contains(octets[1]))
            return isPrivate ? "LAN IPv4" : "public IPv4"
        }
        return host.contains(".") ? "domain" : "single-label host"
    }

    // MARK: - Response fingerprint

    /// e.g. `HTTP 200 · text/html · 5.1 KB · HTML page "Just a moment..."`.
    static func fingerprint(response: URLResponse?, data: Data?) -> String {
        var parts: [String] = []
        if let http = response as? HTTPURLResponse {
            parts.append("HTTP \(http.statusCode)")
            if let type = http.value(forHTTPHeaderField: "Content-Type") {
                parts.append(type.split(separator: ";").first.map(String.init) ?? type)
            }
            if let server = http.value(forHTTPHeaderField: "Server") {
                // Product token only ("cloudflare", "nginx"), no version detail.
                parts.append("server \(server.split(separator: "/").first.map(String.init) ?? server)")
            }
        } else if response != nil {
            parts.append("non-HTTP response")
        }
        if let data {
            parts.append(DeviceDiagnostics.byteString(Int64(data.count)))
            parts.append(bodyKind(data))
        }
        return parts.joined(separator: " · ")
    }

    /// Classifies a body without quoting anything that could be personal.
    static func bodyKind(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty body" }
        let head = data.prefix(4096)
        guard let text = String(bytes: head, encoding: .utf8) ?? String(bytes: head, encoding: .isoLatin1) else {
            return "binary body"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if trimmed.hasPrefix("#EXTM3U") { return "m3u playlist" }
        if lower.hasPrefix("<?xml") || lower.hasPrefix("<tv") {
            return lower.contains("<tv") ? "XMLTV document" : "XML document"
        }
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || lower.contains("<body") {
            var kind = "HTML page"
            if let title = htmlTitle(in: trimmed) { kind += " \"\(title)\"" }
            if lower.contains("cf-chl") || lower.contains("cloudflare") { kind += " (Cloudflare)" }
            return kind
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return jsonKind(data)
        }
        if trimmed == "null" { return "JSON null" }
        // Short plain text is usually a canned refusal ("Authorization failed.",
        // "Access denied"); quote it, scrubbed and capped.
        let snippet = LogRedaction.scrubURLs(in: String(trimmed.prefix(80)))
            .replacingOccurrences(of: "\n", with: " ")
        return "text \"\(snippet)\(trimmed.count > 80 ? "…" : "")\""
    }

    private static func jsonKind(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return data.count >= 4096 ? "JSON (truncated or invalid)" : "invalid JSON"
        }
        switch object {
        case let dictionary as [String: Any]:
            let keys = dictionary.keys.sorted().prefix(12).joined(separator: ", ")
            return "JSON object {\(keys)\(dictionary.count > 12 ? ", …" : "")}"
        case let array as [Any]:
            return "JSON array (\(array.count) items)"
        default:
            return "JSON scalar"
        }
    }

    private static func htmlTitle(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let tagEnd = html[open.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: tagEnd ..< html.endIndex)
        else { return nil }
        let title = html[html.index(after: tagEnd) ..< close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return LogRedaction.scrubURLs(in: String(title.prefix(60)))
    }
}
