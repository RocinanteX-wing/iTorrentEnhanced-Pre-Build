import Foundation

/// Keeps secrets out of logs, error messages and UI strings.
public enum URLRedaction {
    /// Header names whose values must never be logged or persisted.
    public static let sensitiveHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "x-api-key", "x-auth-token", "x-csrf-token", "api-key",
    ]

    public static func isSensitiveHeader(_ name: String) -> Bool {
        sensitiveHeaderNames.contains(name.lowercased())
    }

    /// `scheme://host[:port]/path` without user info, query or fragment; long opaque path segments are masked.
    public static func redacted(_ url: URL) -> String {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme, let host = c.host, !host.isEmpty else { return "<url>" }
        var out = "\(scheme)://\(host)"
        if let port = c.port { out += ":\(port)" }
        out += c.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { maskOpaque(String($0)) }
            .joined(separator: "/")
        if c.percentEncodedQuery != nil { out += "?…" }
        return out
    }

    public static func redacted(_ string: String) -> String {
        guard let url = URL(string: string) else { return "<url>" }
        return redacted(url)
    }

    public static func host(_ url: URL) -> String { url.host ?? "" }

    public static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.mapValues { $0 }.reduce(into: [:]) { out, pair in
            out[pair.key] = isSensitiveHeader(pair.key) ? "<redacted>" : pair.value
        }
    }

    /// Removes sensitive headers entirely (used before writing anything to disk).
    public static func strippingSensitiveHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { !isSensitiveHeader($0.key) }
    }

    /// Replaces every http(s) URL found inside free text (e.g. an error description) with its redacted form.
    public static func redactingURLs(in message: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>)\\]]+", options: [.caseInsensitive]) else { return message }
        let ns = message as NSString
        var result = message
        let matches = regex.matches(in: message, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches {
            let original = ns.substring(with: m.range)
            guard let r = Range(m.range, in: result) else { continue }
            result.replaceSubrange(r, with: redacted(original))
        }
        return result
    }

    private static func maskOpaque(_ segment: String) -> String {
        guard segment.count >= 32 else { return segment }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-%=")
        let opaque = segment.unicodeScalars.allSatisfy { allowed.contains($0) }
        return opaque ? "…" : segment
    }
}
