import Foundation
import FoundationModels

// §8's normalization for the families Apple ships (M6-PLAN D35, Phase 1).
//
// **Un-gated, with `#available` inside — and that is what puts half of this file
// in tier 1.** Phase 0's reading session found the tiering is not where D35
// assumed: `LanguageModelError` is 27-only, but the *deprecated* iOS 26
// `LanguageModelSession.GenerationError` is available at 26, so its mapping and
// its fixtures run in every `swift test` on **any** supported host, 26 included.
// Gating the whole file would have pushed them onto a 27 runtime for nothing.
//
// The distinction still earns its keep now that the build machine is on macOS 27
// and runs both tiers: the package floor is 26, so a 26 host — a CI runner, a
// contributor's machine — must still be able to exercise this half.
//
// **How many families there are was itself a finding.** §8's coverage table
// accounts for `LanguageModelError` and the availability reasons. The 27 SDK
// also ships `LanguageModelSession.Error`, `SystemLanguageModel.Error`, and
// `PrivateCloudComputeLanguageModel.Error`, and the deprecated family carries two
// cases with no §8 analogue. All of it is mapped below, and every mapping §8 does
// not already state is flagged `rev 9` — because §8 states its totality as a
// *checkable* table, and a silent fall-through to `unrecognized` is exactly the
// defect rev 6 fixed for the four `unsupported*` cases.
//
// A note on the `@unknown default` arms: FoundationModels is a resilient
// framework, so its enums are non-frozen and an exhaustive switch cannot be made
// a compile-time tripwire. A new Apple case therefore surfaces as a **loud
// `unrecognized`** at runtime rather than a build break — which is precisely the
// job §8's floor exists to do, and the reason it exists.

/// Thrown error → `GenerationError` (§8), for every error family Apple ships.
///
/// The one entry point the driver calls. Cancellation never arrives here:
/// §7.5 gives it its own terminal, and a driver that normalized a
/// `CancellationError` would turn a user's stop into a failure.
func normalize(_ error: any Error, since now: Date) -> GenerationError {
    // **A tool call error is unwrapped first, because it is a wrapper.**
    // `ToolCallError` says *where* a failure happened — inside an app-supplied
    // tool — not *what* it was, and everything §8 classifies on lives in the
    // error underneath. A tool whose network call timed out should give the user
    // `transport(.timeout)` and a Retry, not an opaque tool-shaped mystery.
    //
    // Nothing is lost by unwrapping: "a tool failed" already has its own channel
    // (§7.6's `toolInvocationRecorded`, carrying the tool's name and a `.failed`
    // status). The terminal says how the *generation* ended; the tool record says
    // what the tool did. Two facts, two events, neither standing in for the other.
    //
    // Bounded, because `ToolCallError` is publicly constructible and its payload
    // is `any Error`: a nested chain is representable, and a class-based error
    // could in principle make one cyclic. Four is generous for "a tool threw a
    // tool error"; past that the floor catches it, loudly, which is I2's posture
    // — never trap, never hang — applied on this side of the seam.
    var error = error
    for _ in 0..<4 {
        guard let call = error as? LanguageModelSession.ToolCallError else { break }
        error = call.underlyingError
    }

    if #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) {
        switch error {
        case let error as LanguageModelError: return normalize(error, since: now)
        case let error as LanguageModelSession.Error: return normalize(error)
        case let error as SystemLanguageModel.Error: return normalize(error)
        case let error as PrivateCloudComputeLanguageModel.Error: return normalize(error, since: now)
        // **An empty model response (rev 9, batch D).** `GeneratedContent`'s
        // parse failure is not confined to guided generation, which is what its
        // name suggests and what `appleErrorSurface` originally assumed: a model
        // producing **zero tokens** fails the same parse on the plain-`String`
        // path, and M6 measured it happening deterministically for particular
        // prompts on Apple's own on-device model.
        //
        // Rule 4, not the floor. The affordance is identical either way — both
        // classify `terminal`, which is *correct*, since retrying an identical
        // request does not fix it (0/10 measured, against 5/5 after rewording;
        // "Regenerate-with-changes is the only path" is literally the remedy).
        // What rule 4 buys is **provenance**: a reproducible, named condition
        // does not belong on the floor reserved for genuine unknowns, and the
        // ledger outlives the session that could have explained it.
        //
        // ⚠️ Deliberately *not* a new `GenerationError` case. §8 spends cases on
        // **affordances**, not conditions — the same argument that groups the
        // four `unsupported*` built-ins — and this one buys no affordance that
        // `terminal` does not already give. It is also the mapping that does not
        // bet on the beta: if a later release routes an empty response to
        // `refusal`, this is one line, where a wire case would be permanent.
        case is GeneratedContent.ParsingError:
            return .providerFailure(status: nil, code: "emptyResponse", message: nil)
        default: break
        }
    }
    // Available at 26, so this arm is reachable — and testable — on a host that
    // cannot run any of the above.
    if let error = error as? LanguageModelSession.GenerationError {
        return normalize(error)
    }
    if let error = error as? URLError {
        return normalize(error)
    }
    // §8's floor, deliberately without the `"driver:"` prefix: this is a provider
    // mystery, not a LedgerKit invariant, and the prefix is what tells the two
    // apart during triage.
    return .unrecognized(description: String(describing: error))
}

/// The floor for a case Apple added after these mappings were written.
///
/// **Deliberately distinguishable from an unknown *provider* error**, which
/// takes the plain floor above. Reading a user's log, "Apple grew a case we do
/// not map" and "some third-party error nobody has seen" want different
/// responses — the first has an obvious fix and a known owner, the second may
/// have neither — and by the time a log reaches triage the type is long gone.
///
/// No `"driver:"` prefix: §8 reserves that for LedgerKit's own *invariants*
/// (the session gate, the non-prefix path), and this is a mapping gap rather
/// than a defect in how the driver behaves.
///
/// `AppleErrorSurfaceTests` is what should catch this first, at build time and
/// with a far better message. This is what the ledger says when nobody ran it.
private func unmapped(_ error: some Error) -> GenerationError {
    .unrecognized(description: "unmapped \(type(of: error)) case: \(error)")
}

// MARK: - LanguageModelError (27) — §8's coverage table, row for row

/// The built-in taxonomy §8 is defined as a total normalization *of*.
///
/// Every row here is §8's coverage table, which is why the table is worth
/// keeping: a reader can diff the two. The one deliberate non-1:1 is `timeout`
/// → `transport(.timeout)`, lift rule 2 — the request never reached a model, so
/// it belongs in the "network, not model" bucket where it classifies retryable.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
func normalize(_ error: LanguageModelError, since now: Date) -> GenerationError {
    switch error {
    case .contextSizeExceeded(let exceeded):
        // Apple's two numbers ride along (D17). LedgerKit's are optional because
        // a non-Apple provider reports neither; here both are present.
        .contextSizeExceeded(contextSize: exceeded.contextSize, tokenCount: exceeded.tokenCount)
    case .rateLimited(let limited):
        // Apple's third `Retry-After` form: an instant, converted here so the
        // ledger stores something clock-independent (§8, rev 7).
        .rateLimited(retryAfter: limited.resetDate.map { retryAfter(resetAt: $0, since: now) })
    case .guardrailViolation:
        .guardrailViolation
    case .refusal:
        // Apple's `Refusal` carries a `debugDescription` and an on-demand
        // `explanation`; §8 projects neither. The name says debug, human detail
        // never classifies, and `explanation` is a *second inference call* whose
        // output has no business being persisted into an append-only ledger.
        .refusal
    case .unsupportedCapability:
        .unsupported(.capability)
    case .unsupportedTranscriptContent:
        .unsupported(.transcriptContent)
    case .unsupportedGenerationGuide:
        .unsupported(.generationGuide)
    case .unsupportedLanguageOrLocale:
        .unsupported(.languageOrLocale)
    case .timeout:
        .transport(.timeout)
    @unknown default:
        unmapped(error)
    }
}

// MARK: - LanguageModelSession.Error (27) — §8's one exclusion

/// Session **misuse**, split out of the iOS 26 enum at 27 — and the reason §8
/// has an exclusion at all.
///
/// Both cases are LedgerKit defects by construction, so both land on the loud
/// floor with the `"driver:"` prefix and **never** on `.rateLimited`. At 26 a
/// single enum carried `concurrentRequests` beside `rateLimited`, which is how
/// "a busy session surfaces as rate limiting" became a plausible reading of the
/// evidence — and classifying a programming error as `retryable` would have had
/// apps politely backing off from their own bug.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
func normalize(_ error: LanguageModelSession.Error) -> GenerationError {
    switch error {
    case .concurrentRequests:
        DriverDiagnostic.sessionBusy.error
    case .transcriptMutationWhileResponding:
        // The driver owns the session for the generation's duration, so nothing
        // else can be mutating its transcript: this is unreachable unless
        // LedgerKit itself is wrong (§8).
        DriverDiagnostic.transcriptMutatedWhileResponding.error
    @unknown default:
        unmapped(error)
    }
}

// MARK: - SystemLanguageModel.Error (27) — §8's second table (landed rev 9)

/// The on-device model's own error type, which §8's coverage table predates.
///
/// Found via the deprecated family's replacement note (`assetsUnavailable` at 26
/// says "use `SystemLanguageModel/Error/assetsUnavailable` instead"), so it is
/// the modern spelling of a condition §8 *does* already have a home for: model
/// assets not on the device is `modelNotReady`, which classifies
/// `recoverableUpstream(.awaitModelDownload)` — exactly the affordance a user
/// waiting on a download needs. **Proposed for rev 9**, since §8 claims totality.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
func normalize(_ error: SystemLanguageModel.Error) -> GenerationError {
    switch error {
    case .assetsUnavailable:
        .modelUnavailable(.modelNotReady)
    @unknown default:
        unmapped(error)
    }
}

// MARK: - PrivateCloudComputeLanguageModel.Error (27) — §8's second table, and
// the one genuinely non-on-device Apple provider

/// Private Cloud Compute's error family. §8 mentions PCC only for its smaller
/// *availability* reason set and not for this enum at all — **proposed for
/// rev 9**.
///
/// The mappings follow §8's existing rules rather than inventing new ones, and
/// the third is the interesting one: §8 already anticipated it in prose.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
func normalize(_ error: PrivateCloudComputeLanguageModel.Error, since now: Date) -> GenerationError {
    switch error {
    case .networkFailure:
        // The request never reached a model — §8's "network, not model" bucket.
        .transport(.connectivity)
    case .quotaLimitReached(let quota):
        // Carries a `resetDate`, which is the same instant-shaped `Retry-After`
        // Apple's `RateLimited` uses, so it normalizes the same way and gets the
        // same `retryable(after:)` affordance.
        .rateLimited(retryAfter: quota.resetDate.map { retryAfter(resetAt: $0, since: now) })
    case .serviceUnavailable:
        // No status to lift and no duration to offer, so §8's rule-4 tail:
        // `terminal`, loudly, with a stable code an app can override. §8
        // describes this exact situation — "if a provider family turns out to
        // emit nil-status transients, that's a mapping override keyed on code"
        // — so the honest landing is the one that leaves Regenerate as the
        // manual retry rather than inventing a 503 the provider never sent.
        .providerFailure(status: nil, code: "serviceUnavailable", message: nil)
    @unknown default:
        unmapped(error)
    }
}

// MARK: - LanguageModelSession.GenerationError (26, deprecated) — the other family

/// The iOS 26 family: **deprecated, not removed**, so a provider package built
/// against 26 can still throw it and normalization must still recognize it
/// (§8, rev 7).
///
/// Available at 26, which makes this the one Apple family whose fixtures run on
/// a host below 27 — the opposite of what D35 expected, and the reason it is
/// mapped in Phase 1 rather than deferred. (The build machine has since reached
/// macOS 27 and runs every tier, but the package floor is 26 and this family is
/// what a 26 host can still cover.)
///
/// It carries **two cases §8's coverage table does not account for**, and both
/// are decided here rather than left to fall through the floor by accident —
/// which is the defect rev 6 fixed for the four `unsupported*` cases, arriving
/// by a different door. Both are **proposed for rev 9**.
func normalize(_ error: LanguageModelSession.GenerationError) -> GenerationError {
    switch error {
    case .exceededContextWindowSize:
        // The 26 spelling of `contextSizeExceeded`, with no numbers to report —
        // which is exactly what LedgerKit's optional fields are for: nil says
        // "not reported" where 0 would claim a measurement.
        .contextSizeExceeded(contextSize: nil, tokenCount: nil)
    case .assetsUnavailable:
        // **rev 9.** Its own deprecation note names the replacement
        // (`SystemLanguageModel.Error.assetsUnavailable`), and model assets that
        // are not present is `modelNotReady` — the same landing §8 already gives
        // PCC's `systemNotReady`.
        .modelUnavailable(.modelNotReady)
    case .guardrailViolation:
        .guardrailViolation
    case .unsupportedGuide:
        .unsupported(.generationGuide)
    case .unsupportedLanguageOrLocale:
        .unsupported(.languageOrLocale)
    case .decodingFailure:
        // **rev 9.** Guided generation's output failed to decode — a condition
        // v0.1 never asks for (N8: LedgerKit requests plain text), so there is no
        // 1:1 home for it and rule 1 does not apply. §8's rule-4 tail does:
        // a provider-custom failure with a stable identifier, classifying
        // `terminal`, which is right because a decode failure is not fixed by
        // retrying the same request. Apple's `Context.debugDescription` is
        // deliberately *not* carried into `message` — §8 declines to project
        // debug detail, and the ledger outlives the session that produced it.
        .providerFailure(status: nil, code: "decodingFailure", message: nil)
    case .rateLimited:
        // The 26 enum reports no duration at all; nil says "not reported".
        .rateLimited(retryAfter: nil)
    case .concurrentRequests:
        // §8's exclusion, in the family where the confusion started: this sits
        // in the *same enum* as `rateLimited`, and mapping it there would
        // classify a LedgerKit bug as `retryable`.
        DriverDiagnostic.sessionBusy.error
    case .refusal:
        .refusal
    @unknown default:
        unmapped(error)
    }
}
