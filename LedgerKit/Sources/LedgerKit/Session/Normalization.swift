import Foundation

// §8's normalization layer — the half that carries no Foundation Models types
// (M6-PLAN D35, Phase 1), so it runs and is fixture-tested on any Mac.
//
// §8 names two layers because the churn lives in the first. **Normalization**
// turns a thrown error into a `GenerationError`; it is empirical, per-provider,
// and expected to change. **Classification** turns a `GenerationError` into a
// `Recoverability`; it is a pure table, lives in `Reduce/`, and shipped at M2.
// Keeping them apart is what makes a mapping gap *retroactively* fixable: the
// ledger stores the error, never the verdict, so historical failures re-classify
// the next time they are reduced.
//
// What lives here is the part every provider family shares — the lift rules, the
// three `Retry-After` forms, the transport bucket, and the `"driver:"` floor —
// so a family file has only to extract facts and hand them over.

/// What a provider reported about a failure, in the four fields §8's rules read.
///
/// Deliberately **not** an error type: provider packages each throw their own,
/// and no two spell these the same way. A per-family file extracts them; this
/// file decides what they mean. `status` is nil for a failure that never crossed
/// an HTTP boundary, which is §8's rule-4 tail rather than a missing value.
struct ProviderFault: Equatable, Sendable {

    /// HTTP status, when the failure crossed an HTTP boundary.
    var status: Int?
    /// The provider's stable machine-readable identifier — **the only field
    /// classification is allowed to read** (§8), and the key an app's override
    /// table is written against.
    var code: String?
    /// Human detail. Never participates in classification; §8 is explicit, and
    /// the rule is what keeps a provider's prose changes from silently changing
    /// an app's affordances.
    var message: String?
    /// The raw `Retry-After` header, in any RFC 9110 form.
    var retryAfter: String?

    init(status: Int? = nil, code: String? = nil, message: String? = nil, retryAfter: String? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }
}

/// Applies §8's lift rules to a provider-reported failure.
///
/// The two lifts exist because these cases must **never** fall through to the
/// generic status classes: a 429 landing as `providerFailure(status: 429)`
/// classifies `retryable(nil)` and throws away the wait the provider just told
/// us about, and a 408 landing there classifies `terminal` when the request
/// simply never reached a model.
///
/// Everything else passes through with its status intact, because the status
/// *classes* are classification's job (§8's table) and normalization
/// pre-empting them would put a verdict in the ledger where a fact belongs.
func normalize(_ fault: ProviderFault, since now: Date) -> GenerationError {
    switch fault.status {
    case 429:
        .rateLimited(retryAfter: fault.retryAfter.flatMap { retryAfter($0, since: now) })
    case 408:
        .transport(.timeout)
    default:
        .providerFailure(status: fault.status, code: fault.code, message: fault.message)
    }
}

/// Parses RFC 9110's `Retry-After` into a duration — both forms, plus the
/// obsolete date formats the RFC still requires recipients to accept.
///
/// **The conversion happens here, at normalization time, and that is a
/// deliberate placement** (§8, rev 7). Turning an instant into a duration reads
/// a clock, which is legal in the driver and forbidden in the reducer (I1). The
/// ledger therefore stores something clock-independent: a duration still means
/// what it meant when a log is opened on another device a week later, where a
/// persisted instant would have quietly become a lie. Display math is
/// `Message.terminalTimestamp + retryAfter`.
///
/// The honest loss, stated: a date form is only as good as the clock skew
/// between device and provider. That is *why* the persisted value is the
/// duration and the instant is recomputed from the terminal's own timestamp.
///
/// Returns nil for anything unparseable — nil means "not reported", which is the
/// same thing a missing header means, and is what `rateLimited(retryAfter: nil)`
/// already says.
func retryAfter(_ header: String, since now: Date) -> Duration? {
    let trimmed = header.trimmingCharacters(in: .whitespaces)

    // Delta-seconds, the common form.
    if let seconds = Int(trimmed) {
        return .seconds(max(0, seconds))
    }

    // HTTP-date. RFC 9110 requires recipients to accept all three formats, and
    // being lenient costs three format strings — where being strict would cost
    // a user their retry affordance because a provider used the 1994 spelling.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed) {
            return retryAfter(resetAt: date, since: now)
        }
    }
    return nil

    // Constructed per call rather than cached, unlike `WireDate`'s formatter:
    // that one is on the append path of every event and was measured; this one
    // runs only when a provider rate-limits *and* answers in dates, where a
    // microsecond is beneath notice and a shared mutable formatter would not be.
}

/// Apple's third `Retry-After` form: an instant rather than a duration
/// (`LanguageModelError.RateLimited.resetDate`, and PCC's `QuotaLimitReached`).
///
/// Clamped at zero: a reset date already in the past means *retry now*, which
/// `.zero` says exactly and a negative duration would say confusingly.
func retryAfter(resetAt reset: Date, since now: Date) -> Duration {
    .seconds(max(0, reset.timeIntervalSince(now)))
}

/// Foundation's URL-loading failures, bucketed into §8's transport classes.
///
/// Unmapped codes deliberately land as `providerFailure(status: nil, code:)`
/// rather than as transport: §8's floor reasoning is that an unclassifiable
/// failure retried blind risks retry loops on permanent faults, and half of
/// `URLError`'s inventory (`.badURL`, `.unsupportedURL`) is a configuration
/// mistake that retrying cannot fix. The numeric code rides along as the stable
/// identifier, so an app can add an override for one without a LedgerKit
/// release — which is §8's rule-4 tail working as designed.
func normalize(_ error: URLError) -> GenerationError {
    switch error.code {
    case .timedOut:
        .transport(.timeout)
    case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
         .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
         .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
        .transport(.tls)
    case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
         .resourceUnavailable, .cannotLoadFromNetwork:
        .transport(.connectivity)
    default:
        .providerFailure(
            status: nil,
            code: "URLError.\(error.code.rawValue)",
            message: error.localizedDescription
        )
    }
}

// MARK: - The driver's own diagnostics

/// A condition the **driver itself** detected, reported through §8's loud floor.
///
/// §8's convention: `unrecognized` values originating in LedgerKit's own driver
/// invariants carry a stable `"driver:"` prefix, so log triage and mapping
/// overrides can tell a driver defect from a provider mystery. Collected into
/// one type so the convention has a single enforcement point rather than a
/// string literal at each site — and so a test can walk the inventory
/// exhaustively, which a scattering of literals could never support.
enum DriverDiagnostic: Equatable, Sendable {

    /// §7.2's gate fired, or its error leaked past it: a second request hit a
    /// responding session.
    ///
    /// **§8's one normalization exclusion.** A busy session is a LedgerKit
    /// defect, never a provider signal, so it must not become `.rateLimited` —
    /// which is precisely what would have happened at iOS 26, where one enum
    /// carried both `concurrentRequests` and `rateLimited`. Classifying a
    /// programming error as `retryable` would have had apps politely backing off
    /// from their own bug.
    case sessionBusy

    /// A transcript was mutated while the session was responding —
    /// `concurrentRequests`' sibling, and unreachable unless LedgerKit is wrong:
    /// the driver owns the session for the generation's whole duration, so
    /// nothing else is in a position to mutate it (§8).
    case transcriptMutatedWhileResponding

    /// A snapshot did not extend its predecessor (§7.3), so the generation dies
    /// rather than the transcript being reconstructed.
    case nonPrefixSnapshot(SnapshotDelta.Reason)

    /// The `GenerationError` this condition becomes.
    var error: GenerationError {
        .unrecognized(description: "driver: \(detail)")
    }

    /// The prose after the prefix. Non-contractual (ADR-001) — the *structure*
    /// asserted in tests is the prefix, never this. The non-prefix case carries
    /// its reason because that string is what a bug report about a real provider
    /// would need to quote, and §14's OQ4 residue is exactly a question about
    /// which of these ever fires in the wild.
    private var detail: String {
        switch self {
        case .sessionBusy:
            "session busy"
        case .transcriptMutatedWhileResponding:
            "transcript mutated while responding"
        case .nonPrefixSnapshot(let reason):
            "non-prefix snapshot (\(reason))"
        }
    }
}

extension SnapshotDelta.Reason: CustomStringConvertible {

    /// Log-facing prose, following ``GenerationError``'s precedent: stated
    /// non-contractual so a rename never becomes someone's shipped-UI
    /// regression, and written by hand so it is not compiler reflection output.
    var description: String {
        switch self {
        case .segmentRevised(let id):
            "segment \(id) was revised"
        case .segmentDropped(let id):
            "segment \(id) disappeared"
        case .segmentsReordered(let expected, let found):
            "expected segment \(expected), found \(found)"
        case .interiorGrowth(let id):
            "segment \(id) grew behind a later segment"
        }
    }
}
