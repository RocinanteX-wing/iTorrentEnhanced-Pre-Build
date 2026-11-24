import Foundation

public enum RangeVerdict: Equatable, Sendable {
    /// The response is exactly what was asked for.
    case accepted
    /// `200` to a ranged request with matching validators: the server ignores `Range`.
    case rangeIgnored
    /// Validators or total size differ from what the download started with.
    case fileChanged
    /// `206` with a missing, malformed or different `Content-Range` (or a wrong length).
    case rangeMismatch(String)
    /// `416`.
    case unsatisfiable
    /// 401 / 403 / 404 / 410: needs the user (expired link, login required...).
    case accessDenied(Int)
    /// 408 / 425 / 429 / 5xx: try again later.
    case retryable(Int)
    case failed(Int)
}

public struct RangeExpectation: Sendable, Equatable {
    public var range: ClosedRange<Int64>
    public var knownTotal: Int64?
    public var validators: Validators
    public init(range: ClosedRange<Int64>, knownTotal: Int64?, validators: Validators) {
        self.range = range; self.knownTotal = knownTotal; self.validators = validators
    }
}

public enum RangeResponseValidator {
    /// Validates the answer to a `Range: bytes=lo-hi` request. Prevents wrong data from ever being assembled.
    public static func verdict(for r: HTTPResponseInfo, expecting x: RangeExpectation) -> RangeVerdict {
        if let v = nonSuccess(r.statusCode, accepting: [200, 206]) { return v }
        let changed = x.validators.compare(to: Validators(response: r)) == .different

        if r.statusCode == 200 {
            return changed ? .fileChanged : .rangeIgnored
        }

        guard let header = r.header("content-range") else { return .rangeMismatch("missing Content-Range") }
        guard let cr = ContentRange.parse(header), let s = cr.start, let e = cr.end else {
            return .rangeMismatch("invalid Content-Range")
        }
        if s != x.range.lowerBound || e != x.range.upperBound {
            return .rangeMismatch("Content-Range \(s)-\(e) does not match requested \(x.range.lowerBound)-\(x.range.upperBound)")
        }
        if let known = x.knownTotal, let t = cr.total, known != t { return .fileChanged }
        if changed { return .fileChanged }
        if r.hasContentEncoding { return .rangeMismatch("content-coded response to a ranged request") }
        if let cl = r.contentLength, cl != e - s + 1 {
            return .rangeMismatch("Content-Length \(cl) does not match range length \(e - s + 1)")
        }
        return .accepted
    }

    /// Validates the answer to a request without `Range` (single-stream download).
    public static func verdictForFullResponse(_ r: HTTPResponseInfo, expectedTotal: Int64?, validators: Validators) -> RangeVerdict {
        if let v = nonSuccess(r.statusCode, accepting: [200]) { return v }
        if r.statusCode == 206 { return .rangeMismatch("unexpected 206 for a request without Range") }
        if validators.compare(to: Validators(response: r)) == .different { return .fileChanged }
        if let expected = expectedTotal, !r.hasContentEncoding, let cl = r.contentLength, cl != expected { return .fileChanged }
        return .accepted
    }

    private static func nonSuccess(_ code: Int, accepting ok: Set<Int>) -> RangeVerdict? {
        if ok.contains(code) { return nil }
        switch code {
        case 416: return .unsatisfiable
        case 401, 403, 404, 410: return .accessDenied(code)
        case 408, 425, 429, 500...599: return .retryable(code)
        case 206 where !ok.contains(206): return nil
        default: return .failed(code)
        }
    }
}
