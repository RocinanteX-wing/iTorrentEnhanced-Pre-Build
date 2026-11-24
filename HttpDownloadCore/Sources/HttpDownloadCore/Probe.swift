import Foundation

public struct ProbeResult: Codable, Sendable, Equatable {
    public var finalURL: URL
    public var totalBytes: Int64?
    public var acceptsRanges: Bool
    public var validators: Validators
    public var contentType: String?
    public var suggestedFilename: String
}

public enum ProbeFailure: Error, Equatable, Sendable {
    case accessDenied(Int)      // 401 / 403
    case notFound(Int)          // 404 / 410
    case serverError(Int)       // 5xx / 429 / 408
    case unexpectedStatus(Int)
    case noResponse
}

/// Turns the raw answers to a `HEAD` request and/or a `GET Range: bytes=0-0` request into a `ProbeResult`.
/// Requests are sent with `Accept-Encoding: identity`, so a content-coded answer means sizes are unreliable.
public enum ProbeInterpreter {
    public static func interpret(head: HTTPResponseInfo?, rangeProbe: HTTPResponseInfo?, requestedURL: URL) throws -> ProbeResult {
        guard head != nil || rangeProbe != nil else { throw ProbeFailure.noResponse }
        let headOK = head.flatMap { (200..<300).contains($0.statusCode) ? $0 : nil }
        let rangeOK = rangeProbe.flatMap { (200..<300).contains($0.statusCode) ? $0 : nil }
        if headOK == nil && rangeOK == nil {
            throw failure(for: (rangeProbe ?? head)!.statusCode)
        }

        var total: Int64?
        var accepts = false
        var coded = false

        if let r = rangeOK {
            coded = r.hasContentEncoding
            if r.statusCode == 206, let cr = r.header("content-range").flatMap(ContentRange.parse), cr.start == 0, cr.end == 0 {
                accepts = !coded
                total = cr.total ?? headOK?.contentLength
            } else if r.statusCode == 200 {
                accepts = false
                total = r.contentLength ?? headOK?.contentLength
            } else {
                accepts = false
                total = headOK?.contentLength
            }
        } else if let h = headOK {
            coded = h.hasContentEncoding
            let ar = h.header("accept-ranges")?.lowercased() ?? ""
            accepts = ar.contains("bytes") && !ar.contains("none")
            total = h.contentLength
        }
        if headOK?.hasContentEncoding == true { coded = true }
        if coded { accepts = false; total = nil }

        let primary = (rangeOK ?? headOK)!
        let validators = Validators(response: primary).isEmpty && headOK != nil ? Validators(response: headOK!) : Validators(response: primary)
        let finalURL = primary.url ?? headOK?.url ?? requestedURL
        let disposition = primary.header("content-disposition") ?? headOK?.header("content-disposition")
        return ProbeResult(
            finalURL: finalURL,
            totalBytes: total,
            acceptsRanges: accepts,
            validators: validators,
            contentType: primary.header("content-type") ?? headOK?.header("content-type"),
            suggestedFilename: FilenameResolver.resolve(contentDisposition: disposition, url: finalURL)
        )
    }

    public static func failure(for status: Int) -> ProbeFailure {
        switch status {
        case 401, 403: return .accessDenied(status)
        case 404, 410: return .notFound(status)
        case 408, 425, 429, 500...599: return .serverError(status)
        default: return .unexpectedStatus(status)
        }
    }
}
