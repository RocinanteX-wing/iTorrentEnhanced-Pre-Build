import Foundation

/// Parsed `Content-Range` response header.
public struct ContentRange: Equatable, Sendable {
    public var start: Int64?
    public var end: Int64?
    public var total: Int64?

    /// `bytes */1234` (as sent with 416).
    public var isUnsatisfied: Bool { start == nil }

    public static func parse(_ header: String) -> ContentRange? {
        let h = header.trimmingCharacters(in: .whitespaces)
        guard h.lowercased().hasPrefix("bytes") else { return nil }
        let rest = h.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rangePart = parts[0].trimmingCharacters(in: .whitespaces)
        let totalPart = parts[1].trimmingCharacters(in: .whitespaces)

        var total: Int64?
        if totalPart != "*" {
            guard let t = Int64(totalPart), t >= 0 else { return nil }
            total = t
        }
        if rangePart == "*" { return ContentRange(start: nil, end: nil, total: total) }
        let se = rangePart.split(separator: "-", omittingEmptySubsequences: false)
        guard se.count == 2, let s = Int64(se[0]), let e = Int64(se[1]), s >= 0, e >= s else { return nil }
        if let t = total, e >= t { return nil }
        return ContentRange(start: s, end: e, total: total)
    }
}

/// Extracts a file name from `Content-Disposition` (RFC 6266 / RFC 5987).
public enum ContentDisposition {
    public static func filename(from header: String) -> String? {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in header {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == ";" && !inQuotes { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)

        var plain: String?
        var extended: String?
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let name = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if name == "filename*" { extended = decodeExtended(value) }
            else if name == "filename" { plain = unquote(value) }
        }
        return extended ?? plain
    }

    private static func unquote(_ v: String) -> String {
        guard v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") else { return v }
        let inner = v.dropFirst().dropLast()
        var out = ""
        var esc = false
        for ch in inner {
            if esc { out.append(ch); esc = false }
            else if ch == "\\" { esc = true }
            else { out.append(ch) }
        }
        return out
    }

    /// `UTF-8''%e2%82%ac%20rates.txt`
    private static func decodeExtended(_ v: String) -> String? {
        let pieces = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let charset = pieces[0].lowercased()
        guard let bytes = percentDecode(String(pieces[2])) else { return nil }
        switch charset {
        case "utf-8", "utf8": return String(bytes: bytes, encoding: .utf8)
        case "iso-8859-1", "latin1": return String(bytes: bytes, encoding: .isoLatin1)
        default: return nil
        }
    }

    private static func percentDecode(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "%") {
                guard i + 2 < u.count, let hi = hex(u[i + 1]), let lo = hex(u[i + 2]) else { return nil }
                out.append(UInt8(hi * 16 + lo)); i += 3
            } else { out.append(u[i]); i += 1 }
        }
        return out
    }

    private static func hex(_ c: UInt8) -> Int? {
        switch c {
        case 48...57: return Int(c) - 48
        case 65...70: return Int(c) - 55
        case 97...102: return Int(c) - 87
        default: return nil
        }
    }
}

/// Makes a server- or URL-supplied name safe to use as a local file name.
public enum FilenameSanitizer {
    public static let maxBytes = 200

    public static func sanitize(_ raw: String, fallback: String = "download") -> String {
        var s = raw.replacingOccurrences(of: "\0", with: "")
        if let last = s.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last { s = String(last) } else { s = "" }

        let bad = CharacterSet(charactersIn: ":*?\"<>|").union(.controlCharacters)
        var cleaned = ""
        for u in s.unicodeScalars { cleaned.unicodeScalars.append(bad.contains(u) ? "_" : u) }
        s = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        if s.isEmpty { return fallback }

        if s.utf8.count > maxBytes {
            let ns = s as NSString
            let ext = ns.pathExtension
            var base = ext.isEmpty ? s : ns.deletingPathExtension
            let suffix = (ext.isEmpty || ext.utf8.count > 16) ? "" : "." + ext
            if suffix.isEmpty { base = s }
            while (base.utf8.count + suffix.utf8.count) > maxBytes, !base.isEmpty { base.removeLast() }
            s = base + suffix
            if s.isEmpty { return fallback }
        }
        return s
    }
}

public enum FilenameResolver {
    public static func resolve(contentDisposition: String?, url: URL, fallback: String = "download") -> String {
        if let cd = contentDisposition, let n = ContentDisposition.filename(from: cd) {
            let s = FilenameSanitizer.sanitize(n, fallback: "")
            if !s.isEmpty { return s }
        }
        let last = url.lastPathComponent
        if last != "/" && !last.isEmpty {
            let s = FilenameSanitizer.sanitize(last, fallback: "")
            if !s.isEmpty { return s }
        }
        return fallback
    }
}

public enum UniqueFilename {
    /// "name.ext" -> "name (1).ext" -> "name (2).ext" ... until `exists` says the name is free.
    public static func resolve(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        for i in 1...9999 {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if !exists(candidate) { return candidate }
        }
        let token = String(UUID().uuidString.prefix(8))
        return ext.isEmpty ? "\(base)-\(token)" : "\(base)-\(token).\(ext)"
    }
}
