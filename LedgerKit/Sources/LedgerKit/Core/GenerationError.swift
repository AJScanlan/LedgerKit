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
    /// Why the model cannot run at all.
    ///
    /// Normalizes `SystemLanguageModel.Availability.UnavailableReason`, **not**
    /// a `LanguageModelError` case (SPEC rev 6) — availability is a separate
    /// API the app queries *before* generating. Names mirror it exactly.
    case modelUnavailable(ModelUnavailability)
    /// Mirrors `LanguageModelError.contextSizeExceeded`. Named
    /// `contextWindowExceeded` until SPEC rev 6, which matched no Apple case;
    /// the old wire tag is reserved forever (ADR-001).
    case contextSizeExceeded
    /// A safety system intervened on the content.
    case guardrailViolation
    /// The model itself declined to answer.
    ///
    /// Deliberately distinct from ``guardrailViolation`` even though both
    /// classify `.terminal` today: Apple keeps them apart, the difference is
    /// real — a guardrail intervening versus the model declining — and
    /// collapsing them would discard it permanently to save one case.
    /// Apple's `Refusal.debugDescription` is not projected: the name says
    /// debug, and §8's rule is that human detail never classifies.
    case refusal
    /// The app asked this model for something it does not do.
    ///
    /// Groups Apple's four `unsupported*` cases, which before SPEC rev 6 fell
    /// through to ``unrecognized`` — the floor whose job is to be loud about
    /// what the taxonomy failed to anticipate, quietly absorbing four cases it
    /// had in fact been shown. Grouped rather than lifted because all four
    /// classify `.terminal` and three of four are configuration errors.
    case unsupported(UnsupportedFeature)
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

/// Why the model can't run at all — mirrors
/// `SystemLanguageModel.Availability.UnavailableReason` exactly (SPEC §8).
///
/// `PrivateCloudComputeLanguageModel` publishes a smaller set
/// (`deviceNotEligible`, `systemNotReady`); its `systemNotReady` normalizes to
/// ``modelNotReady``.
public enum ModelUnavailability: String, Sendable, Codable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
}

/// Which unsupported-feature failure occurred (SPEC §8) — the nested half of
/// ``GenerationError/unsupported(_:)``.
///
/// One case per Apple `unsupported*` built-in, so the grouping loses no
/// information. All four classify `.terminal`; the value is for logging and
/// developer diagnosis, since three of the four say the *app* asked for
/// something this model cannot do.
public enum UnsupportedFeature: String, Sendable, Codable {
    /// Tools, guided generation, or reasoning this model lacks.
    case capability
    /// A transcript entry kind or segment the model cannot consume.
    case transcriptContent
    /// A schema the model cannot satisfy.
    case generationGuide
    /// The prompt's language or locale is out of scope for this model.
    case languageOrLocale
}

/// Transport-layer failure classes (SPEC §8): the request never got a model
/// answer. All retryable by the default mapping.
public enum TransportFailure: String, Sendable, Codable {
    case timeout
    case connectivity
    case tls
}

// MARK: - Diagnostics

extension GenerationError: CustomStringConvertible {

    /// Log-facing prose, following ``QuarantineReason``'s precedent:
    /// **non-contractual by ADR-001** — reword freely, and never match on it.
    /// Switch on the cases; that is what they are for.
    ///
    /// This exists so the alternative doesn't happen. Without it, an app
    /// rendering a failed bubble's detail disclosure reaches for
    /// `String(describing:)`, which is compiler-generated reflection output —
    /// and Hyrum's Law then freezes *that* into shipped UI, where a future case
    /// rename becomes a visible regression in somebody else's product. A stated
    /// non-contractual rendering is the cheaper thing to own.
    ///
    /// Note what is deliberately *not* here: any classification hint. UI
    /// affordance is a function of ``Recoverability``, never of error text or
    /// error inspection (SPEC §8).
    public var description: String {
        switch self {
        case .modelUnavailable(let reason):
            "model unavailable: \(reason.rawValue)"
        case .contextSizeExceeded:
            "context size exceeded"
        case .guardrailViolation:
            "guardrail violation"
        case .refusal:
            "the model declined to answer"
        case .unsupported(let feature):
            "unsupported by this model: \(feature.rawValue)"
        case .rateLimited(let retryAfter):
            retryAfter.map { "rate limited, retry after \($0)" } ?? "rate limited"
        case .providerFailure(let status, let code, let message):
            // Assembled from the parts that are present, in decreasing
            // reliability: status classifies, code identifies, message explains
            // and is the only free-text member.
            (["provider failure"]
                + [status.map { "status \($0)" }, code.map { "code \($0)" }, message]
                .compactMap(\.self))
                .joined(separator: ": ")
        case .transport(let failure):
            "transport failure: \(failure.rawValue)"
        case .unrecognized(let description):
            // Already prose, and already loud — pass it through rather than
            // wrapping it in a second layer of ours. Driver-originated values
            // carry the `"driver:"` prefix that makes them self-identifying.
            "unrecognized: \(description)"
        }
    }
}

// MARK: - Wire coding

extension GenerationError: Codable {
    /// Raw values **are the wire** (ADR-001 R-3): a Swift case rename must keep
    /// its raw value, and a retired tag is reserved forever rather than reused.
    /// `contextWindowExceeded` was retired at SPEC rev 6 and is listed in
    /// ADR-001's reserved table; no upcaster is needed because no released
    /// version ever wrote it.
    private enum Kind: String {
        case modelUnavailable
        case contextSizeExceeded
        case guardrailViolation
        case refusal
        case unsupported
        case rateLimited
        case providerFailure
        case transport
        case unrecognized
    }

    private enum CodingKeys: String, CodingKey {
        case kind, reason, feature, retryAfter, status, code, message, failure, description
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
        case .contextSizeExceeded:
            self = .contextSizeExceeded
        case .guardrailViolation:
            self = .guardrailViolation
        case .refusal:
            self = .refusal
        case .unsupported:
            self = .unsupported(try container.decode(UnsupportedFeature.self, forKey: .feature))
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
        case .contextSizeExceeded:
            try container.encode(Kind.contextSizeExceeded.rawValue, forKey: .kind)
        case .guardrailViolation:
            try container.encode(Kind.guardrailViolation.rawValue, forKey: .kind)
        case .refusal:
            try container.encode(Kind.refusal.rawValue, forKey: .kind)
        case .unsupported(let feature):
            try container.encode(Kind.unsupported.rawValue, forKey: .kind)
            try container.encode(feature, forKey: .feature)
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
