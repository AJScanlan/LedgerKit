import Foundation

/// Why a generation failed (SPEC §8) — a total normalization of Apple's
/// built-in `LanguageModelError` taxonomy first, with `providerFailure` /
/// `transport` as the custom-error tail and `unrecognized` as the floor.
///
/// Persisted inside `Outcome.failed`. Its dual, `Recoverability`, is derived
/// at classification time and stored nowhere — fixing a mapping gap
/// retroactively upgrades historical failed messages on the next reduction.
///
/// UI affordance is a function of `Recoverability`, never of raw error
/// inspection.
public enum GenerationError: Error, Sendable, Equatable {
    /// ⚠️ Case names mirror Apple's exactly; verify against the beta at M6
    /// (OQ5).
    case modelUnavailable(ModelUnavailability)
    case contextWindowExceeded
    case guardrailViolation
    /// `retryAfter` is normalized to a duration at normalization time (both
    /// RFC 9110 `Retry-After` forms), so the persisted value is
    /// clock-independent; display math is `terminalTimestamp + retryAfter`.
    case rateLimited(retryAfter: Duration?)
    /// A failure that crossed a provider boundary. `status` is the HTTP
    /// status when one exists; `code` is the provider's stable
    /// machine-readable identifier and the only classification input;
    /// `message` is human detail and never participates in classification.
    case providerFailure(status: Int?, code: String?, message: String?)
    /// The "network, not model" bucket — timeout, connectivity, TLS.
    case transport(TransportFailure)
    /// The loud floor — never silently swallowed. Driver-originated values
    /// carry a stable `"driver:"` prefix (SPEC §8).
    case unrecognized(description: String)
}

/// Why the model can't run at all — mirrors Apple's availability cases
/// (⚠️ OQ5, pin at M6).
public enum ModelUnavailability: String, Sendable, Codable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
}

/// Transport-layer failure classes (SPEC §8): the request never got a model
/// answer. All retryable by the default mapping.
public enum TransportFailure: String, Sendable, Codable {
    case timeout
    case connectivity
    case tls
}

// MARK: - Wire coding

extension GenerationError: Codable {
    private enum Kind: String {
        case modelUnavailable
        case contextWindowExceeded
        case guardrailViolation
        case rateLimited
        case providerFailure
        case transport
        case unrecognized
    }

    private enum CodingKeys: String, CodingKey {
        case kind, reason, retryAfter, status, code, message, failure, description
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown error kind: \(rawKind)"
            )
        }
        switch kind {
        case .modelUnavailable:
            self = .modelUnavailable(try container.decode(ModelUnavailability.self, forKey: .reason))
        case .contextWindowExceeded:
            self = .contextWindowExceeded
        case .guardrailViolation:
            self = .guardrailViolation
        case .rateLimited:
            self = .rateLimited(
                retryAfter: (try container.decodeIfPresent(Int64.self, forKey: .retryAfter))
                    .map(Duration.init(wireMilliseconds:))
            )
        case .providerFailure:
            self = .providerFailure(
                status: try container.decodeIfPresent(Int.self, forKey: .status),
                code: try container.decodeIfPresent(String.self, forKey: .code),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case .transport:
            self = .transport(try container.decode(TransportFailure.self, forKey: .failure))
        case .unrecognized:
            self = .unrecognized(description: try container.decode(String.self, forKey: .description))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .modelUnavailable(let reason):
            try container.encode(Kind.modelUnavailable.rawValue, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .contextWindowExceeded:
            try container.encode(Kind.contextWindowExceeded.rawValue, forKey: .kind)
        case .guardrailViolation:
            try container.encode(Kind.guardrailViolation.rawValue, forKey: .kind)
        case .rateLimited(let retryAfter):
            try container.encode(Kind.rateLimited.rawValue, forKey: .kind)
            try container.encodeIfPresent(retryAfter?.wireMilliseconds, forKey: .retryAfter)
        case .providerFailure(let status, let code, let message):
            try container.encode(Kind.providerFailure.rawValue, forKey: .kind)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encodeIfPresent(code, forKey: .code)
            try container.encodeIfPresent(message, forKey: .message)
        case .transport(let failure):
            try container.encode(Kind.transport.rawValue, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        case .unrecognized(let description):
            try container.encode(Kind.unrecognized.rawValue, forKey: .kind)
            try container.encode(description, forKey: .description)
        }
    }
}
