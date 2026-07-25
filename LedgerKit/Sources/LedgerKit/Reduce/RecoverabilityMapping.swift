/// The `GenerationError -> Recoverability` classification table (SPEC §8).
///
/// A **value**, not a closure or a protocol, and that is load-bearing for I1.
/// The spec says *"same `FoldedState` + same mapping ⇒ same `Conversation`."*
/// For a closure, "same mapping" is inexpressible — closures have no equality —
/// so that half of I1 could never be asserted. Being `Equatable` turns a
/// sentence in the spec into a test in CI.
///
/// It also makes purity structural rather than promised: a closure can capture
/// mutable state or read a clock and violate I1 invisibly, where a table of
/// constants cannot (tenet 1). And it gives §8's per-provider `code` table a
/// natural home.
///
/// **Slots map 1:1 onto §8's rows**, deliberately, so the table can be diffed
/// against the spec — §8 warns this mapping "is expected to churn," which is
/// exactly when a reviewable shape earns its keep.
///
/// **Construction is `.default` plus mutation**, which is also the §8 model
/// ("ships in LedgerKit; apps override per-case"):
///
/// ```swift
/// var mapping = RecoverabilityMapping.default
/// mapping.guardrailViolation = .retryable(after: nil)
/// ```
///
/// There is deliberately no public memberwise initializer. Apps always start
/// from `.default`, so adding a row later stays source-compatible — a 13-parameter
/// public init would make every new §8 row a breaking change.
///
/// Not `Codable`, and never persisted: `Recoverability` is derived at
/// classification time so that fixing a mapping gap *retroactively upgrades* the
/// affordances on historical failed messages. Classification bugs heal; frozen
/// classifications don't (§8).
public struct RecoverabilityMapping: Sendable, Equatable {

    /// The table that ships with LedgerKit — §8's default mapping, row for row.
    public static let `default` = Self(
        deviceNotEligible: .terminal,
        appleIntelligenceNotEnabled: .recoverableUpstream(.enableAppleIntelligence),
        modelNotReady: .recoverableUpstream(.awaitModelDownload),
        contextWindowExceeded: .recoverableUpstream(.reduceContext),
        guardrailViolation: .terminal,
        transport: .retryable(after: nil),
        providerRateLimited: .retryable(after: nil),
        providerAuthenticationFailure: .recoverableUpstream(.reauthenticate),
        providerClientError: .terminal,
        providerServerError: .retryable(after: nil),
        providerCodes: [:],
        providerUnmatchedCode: .terminal,
        providerUnclassified: .terminal,
        unrecognized: .terminal
    )

    // MARK: Apple's built-in taxonomy (§8, rows 1–5)

    /// The device cannot run the model at all — nothing the app can do.
    public var deviceNotEligible: Recoverability
    public var appleIntelligenceNotEnabled: Recoverability
    public var modelNotReady: Recoverability
    public var contextWindowExceeded: Recoverability
    public var guardrailViolation: Recoverability

    /// Every `TransportFailure` — timeout, connectivity, TLS. §8 has one row for
    /// all three; widen to `[TransportFailure: Recoverability]` if a real case
    /// appears for treating TLS as configuration rather than transience.
    public var transport: Recoverability

    // MARK: Provider failures, by status class (§8)

    /// HTTP 429. **Defensive only** — normalization's lift rules should have
    /// turned this into `.rateLimited` before it ever reached classification
    /// (§8 rule 2), so reaching this slot means a normalization gap.
    public var providerRateLimited: Recoverability

    /// HTTP 401 / 403 / 407 — the row that makes the reauth bubble reachable
    /// through observation (§7.2).
    public var providerAuthenticationFailure: Recoverability

    /// Any other 4xx.
    public var providerClientError: Recoverability

    /// Any 5xx.
    public var providerServerError: Recoverability

    /// Per-provider overrides keyed on the provider's stable `code`, consulted
    /// **only when there is no HTTP status** (§8's row for `status nil, code
    /// non-nil`). A status, where one exists, is the more reliable signal and
    /// wins; if a provider family turns out to need code-keyed overrides
    /// *alongside* a status, that is a deliberate widening, not a bug fix.
    public var providerCodes: [String: Recoverability]

    /// No status, and a `code` that `providerCodes` does not match. §8: unmatched
    /// → `terminal`, loudly. Retrying an unclassifiable failure blind risks retry
    /// loops on permanent faults, and `terminal` still leaves Regenerate as the
    /// manual retry — the safer default.
    public var providerUnmatchedCode: Recoverability

    /// No status and no code — nothing to classify on. Also the floor for a
    /// status outside 4xx/5xx, which §8's table does not enumerate.
    public var providerUnclassified: Recoverability

    // MARK: The floor (§8)

    /// The loud floor. Driver-originated values carry a `"driver:"` prefix, so
    /// log triage can separate driver defects from provider mysteries.
    public var unrecognized: Recoverability

    // MARK: - Classifying

    /// The pure §8 mapping. Total by construction: the switch is exhaustive over
    /// `GenerationError`, so a new error case cannot be added without being
    /// given a home here.
    ///
    /// Note `rateLimited` has no slot — its answer is `retryable(after:)` reading
    /// the error's *own* duration, which normalization already made
    /// clock-independent (§8). It reads a payload rather than a constant, so
    /// there is nothing to override.
    public func recoverability(for error: GenerationError) -> Recoverability {
        switch error {
        case .modelUnavailable(.deviceNotEligible): deviceNotEligible
        case .modelUnavailable(.appleIntelligenceNotEnabled): appleIntelligenceNotEnabled
        case .modelUnavailable(.modelNotReady): modelNotReady
        case .contextWindowExceeded: contextWindowExceeded
        case .guardrailViolation: guardrailViolation
        case .rateLimited(let retryAfter): .retryable(after: retryAfter)
        case .transport: transport
        case .providerFailure(let status, let code, _): providerFailure(status: status, code: code)
        case .unrecognized: unrecognized
        }
    }

    /// §8's status-class rows, in precedence order.
    ///
    /// `message` is deliberately not a parameter: §8 states it is human detail
    /// and **never** participates in classification, and the surest way to honour
    /// that is to make it unavailable here.
    private func providerFailure(status: Int?, code: String?) -> Recoverability {
        guard let status else {
            guard let code else { return providerUnclassified }
            return providerCodes[code] ?? providerUnmatchedCode
        }
        switch status {
        // 429 first: it is a 4xx, and falling through to `providerClientError`
        // would classify a rate limit as terminal.
        case 429: return providerRateLimited
        // Likewise 401/403/407 before the general 4xx row.
        case 401, 403, 407: return providerAuthenticationFailure
        case 400...499: return providerClientError
        case 500...599: return providerServerError
        // §8's table enumerates only 4xx and 5xx. A failure reporting some other
        // status is malformed rather than meaningful, so it takes the loud floor.
        default: return providerUnclassified
        }
    }
}
