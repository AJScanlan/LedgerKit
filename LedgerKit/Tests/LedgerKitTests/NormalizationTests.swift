import Foundation
import FoundationModels
import Testing
@testable import LedgerKit

// §10.5's error-mapping fixtures: canned provider failures → asserted
// `GenerationError` **and** `Recoverability`, per family.
//
// Both layers are asserted together on purpose. Normalization alone can look
// right and still hand the user the wrong affordance — a 429 landing as
// `providerFailure(status: 429)` is a *plausible* normalization that classifies
// `retryable(nil)` and silently discards the wait the provider just reported.
// The lift rules exist to prevent exactly that, so the tests state the
// consequence rather than the intermediate.
//
// Tier 1 (this file's first suite) runs everywhere: the pure rules, `URLError`,
// and — a Phase 0 finding — the **deprecated iOS 26 family**, which is available
// at 26 and so needs no gate at all. Tier 2 is the 27-only families, gated and
// executed on the iOS 27 simulator.

@Suite("Session — normalization (§8)")
struct NormalizationTests {

    private let mapping = RecoverabilityMapping.default

    // MARK: - The lift rules

    /// §8's lift rule 2, and the reason it exists: without it this classifies
    /// `retryable(nil)` and the wait the provider reported is thrown away.
    @Test("429 lifts to rateLimited, carrying the reported wait")
    func rateLimitLift() {
        let fault = ProviderFault(status: 429, code: "rate_limit", retryAfter: "120")
        let error = normalize(fault, since: normalizationNow)

        #expect(error == .rateLimited(retryAfter: .seconds(120)))
        #expect(mapping.recoverability(for: error) == .retryable(after: .seconds(120)))
    }

    /// The request never reached a model, so it belongs in the transport bucket
    /// — where it classifies retryable — rather than in the 4xx class, where it
    /// would classify terminal.
    @Test("408 lifts to transport, not to a client error")
    func timeoutLift() {
        let error = normalize(ProviderFault(status: 408), since: normalizationNow)

        #expect(error == .transport(.timeout))
        #expect(mapping.recoverability(for: error) == .retryable(after: nil))
    }

    /// Everything else keeps its status **unclassified**: the status *classes*
    /// are classification's job, and normalization pre-empting them would put a
    /// verdict in the ledger where a fact belongs.
    @Test("other statuses pass through for classification to judge")
    func statusesPassThrough() {
        let server = normalize(ProviderFault(status: 503, message: "overloaded"), since: normalizationNow)
        #expect(server == .providerFailure(status: 503, code: nil, message: "overloaded"))
        #expect(mapping.recoverability(for: server) == .retryable(after: nil))

        let auth = normalize(ProviderFault(status: 401), since: normalizationNow)
        #expect(auth == .providerFailure(status: 401, code: nil, message: nil))
        #expect(mapping.recoverability(for: auth) == .recoverableUpstream(.reauthenticate))
    }

    /// §8's rule-4 tail: no HTTP boundary, but a stable identifier an app can
    /// write an override against.
    @Test("a non-HTTP provider failure keeps its code")
    func nonHTTPFailure() {
        let error = normalize(ProviderFault(code: "context_overflow"), since: normalizationNow)

        #expect(error == .providerFailure(status: nil, code: "context_overflow", message: nil))
        #expect(mapping.recoverability(for: error) == .terminal)
    }

    /// A 429 whose header is missing or unparseable is still a rate limit — the
    /// duration is what is unknown, not the condition.
    @Test("an unreported wait leaves rateLimited with a nil duration")
    func rateLimitWithoutAWait() {
        #expect(normalize(ProviderFault(status: 429), since: normalizationNow) == .rateLimited(retryAfter: nil))
        #expect(
            normalize(ProviderFault(status: 429, retryAfter: "soon"), since: normalizationNow)
                == .rateLimited(retryAfter: nil)
        )
    }

    // MARK: - Retry-After, all three forms

    @Test("delta-seconds parse, and a negative one clamps to zero")
    func deltaSeconds() {
        #expect(retryAfter("120", since: normalizationNow) == .seconds(120))
        #expect(retryAfter("  30  ", since: normalizationNow) == .seconds(30))
        #expect(retryAfter("-5", since: normalizationNow) == .seconds(0))
    }

    /// RFC 9110 requires recipients to accept all three date formats, including
    /// two obsolete ones — so a provider using the 1994 spelling does not cost a
    /// user their retry affordance.
    @Test("all three RFC 9110 date formats parse to the same duration")
    func httpDates() {
        let base = Date(timeIntervalSince1970: 784_111_777)   // Sun, 06 Nov 1994 08:49:37 GMT
        let expected = Duration.seconds(60)
        let now = base.addingTimeInterval(-60)

        #expect(retryAfter("Sun, 06 Nov 1994 08:49:37 GMT", since: now) == expected)
        #expect(retryAfter("Sunday, 06-Nov-94 08:49:37 GMT", since: now) == expected)
        #expect(retryAfter("Sun Nov  6 08:49:37 1994", since: now) == expected)
    }

    @Test("a date already past means retry now, not a negative wait")
    func pastDate() {
        let now = Date(timeIntervalSince1970: 784_111_777).addingTimeInterval(3600)
        #expect(retryAfter("Sun, 06 Nov 1994 08:49:37 GMT", since: now) == .seconds(0))
    }

    @Test("an unparseable header is not reported rather than guessed at")
    func unparseableHeader() {
        #expect(retryAfter("tomorrow", since: normalizationNow) == nil)
        #expect(retryAfter("", since: normalizationNow) == nil)
    }

    /// Apple's third form. The conversion happens at normalization time so the
    /// ledger stores a duration, which still means what it meant when the log is
    /// reopened on another device (§8, I1).
    @Test("an instant converts to a duration against the supplied clock")
    func resetDateConversion() {
        #expect(retryAfter(resetAt: normalizationNow.addingTimeInterval(45), since: normalizationNow) == .seconds(45))
        #expect(retryAfter(resetAt: normalizationNow.addingTimeInterval(-45), since: normalizationNow) == .seconds(0))
    }

    // MARK: - URLError

    @Test("URLError buckets into the transport classes")
    func urlErrorBuckets() {
        #expect(normalize(URLError(.timedOut)) == .transport(.timeout))
        #expect(normalize(URLError(.notConnectedToInternet)) == .transport(.connectivity))
        #expect(normalize(URLError(.networkConnectionLost)) == .transport(.connectivity))
        #expect(normalize(URLError(.secureConnectionFailed)) == .transport(.tls))
        #expect(mapping.recoverability(for: normalize(URLError(.timedOut))) == .retryable(after: nil))
    }

    /// An unmapped `URLError` is *not* called transport. Half of that enum is a
    /// configuration mistake retrying cannot fix, and §8's floor reasoning is
    /// that blind retries risk loops on permanent faults — so it lands
    /// `terminal` with a stable code an app can override.
    @Test("an unmapped URLError lands as a provider failure, not as transport")
    func unmappedURLError() {
        let error = normalize(URLError(.badURL))

        #expect(error == .providerFailure(
            status: nil,
            code: "URLError.\(URLError.Code.badURL.rawValue)",
            message: URLError(.badURL).localizedDescription
        ))
        #expect(mapping.recoverability(for: error) == .terminal)
    }

    // MARK: - The deprecated iOS 26 family (tier 1 — available at 26)

    /// **Deprecated is not absent** (§8, rev 7): a provider package built against
    /// 26 can still throw this, so normalization must still recognize it.
    ///
    /// Table-driven because the interesting property is *coverage* — every case
    /// decided, none reaching the floor by accident.
    @Test(
        "every case of the deprecated family normalizes",
        arguments: [
            (LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "x")),
             GenerationError.contextSizeExceeded(contextSize: nil, tokenCount: nil)),
            (.assetsUnavailable(.init(debugDescription: "x")), .modelUnavailable(.modelNotReady)),
            (.guardrailViolation(.init(debugDescription: "x")), .guardrailViolation),
            (.unsupportedGuide(.init(debugDescription: "x")), .unsupported(.generationGuide)),
            (.unsupportedLanguageOrLocale(.init(debugDescription: "x")), .unsupported(.languageOrLocale)),
            (.decodingFailure(.init(debugDescription: "x")),
             .providerFailure(status: nil, code: "decodingFailure", message: nil)),
            (.rateLimited(.init(debugDescription: "x")), .rateLimited(retryAfter: nil)),
            (.refusal(.init(transcriptEntries: []), .init(debugDescription: "x")), .refusal),
        ]
    )
    func deprecatedFamily(error: LanguageModelSession.GenerationError, expected: GenerationError) {
        #expect(normalize(error, since: normalizationNow) == expected)
    }

    /// **§8's one exclusion, in the family where the confusion started.** At 26
    /// `concurrentRequests` sits in the same enum as `rateLimited`; mapping it
    /// there would classify a LedgerKit bug as `retryable` and have apps backing
    /// off politely from their own defect.
    @Test("a busy session is never rate limiting")
    func busySessionExclusion() {
        let error = normalize(
            LanguageModelSession.GenerationError.concurrentRequests(.init(debugDescription: "x")),
            since: normalizationNow
        )

        #expect(error == DriverDiagnostic.sessionBusy.error)
        #expect(mapping.recoverability(for: error) == .terminal)
        if case .rateLimited = error { Issue.record("a busy session must never normalize to rateLimited") }
    }

    /// The affordance the `assetsUnavailable` decision buys — the reason it is
    /// `modelNotReady` and not the loud floor.
    @Test("assets unavailable becomes an await-download affordance")
    func assetsUnavailableAffordance() {
        let error = normalize(
            LanguageModelSession.GenerationError.assetsUnavailable(.init(debugDescription: "x")),
            since: normalizationNow
        )

        #expect(mapping.recoverability(for: error) == .recoverableUpstream(.awaitModelDownload))
    }

    // MARK: - Tool call errors (tier 1 — Tool and ToolCallError are both 26)

    /// **A wrapper, so it is unwrapped.** `ToolCallError` says *where* a failure
    /// happened, not what it was — and a tool whose network call timed out should
    /// give the user a Retry, not an opaque tool-shaped mystery.
    ///
    /// Found by Phase 1.5's SDK sweep, not by any earlier read: it is the one
    /// unhandled error type that plainly reaches a *running* generation, since
    /// tools execute inside the session (§7.6).
    @Test("a tool call error normalizes to the error underneath it")
    func toolCallErrorUnwraps() {
        let wrapped = LanguageModelSession.ToolCallError(tool: StubTool(), underlyingError: URLError(.timedOut))

        #expect(normalize(wrapped, since: normalizationNow) == .transport(.timeout))
        #expect(mapping.recoverability(for: normalize(wrapped, since: normalizationNow)) == .retryable(after: nil))
    }

    /// Nesting is bounded rather than trusted: the payload is `any Error` and the
    /// initializer is public, so a chain is representable. Past the bound the
    /// floor catches it — I2's "never trap, never hang" posture on this side of
    /// the seam.
    @Test("a nested chain of tool call errors terminates")
    func nestedToolCallErrors() {
        var error: any Error = URLError(.timedOut)
        for _ in 0..<3 {
            error = LanguageModelSession.ToolCallError(tool: StubTool(), underlyingError: error)
        }
        #expect(normalize(error, since: normalizationNow) == .transport(.timeout))

        // Deeper than the bound: still terminates, still loud.
        for _ in 0..<10 {
            error = LanguageModelSession.ToolCallError(tool: StubTool(), underlyingError: error)
        }
        guard case .unrecognized = normalize(error, since: normalizationNow) else {
            Issue.record("an over-deep chain must land on the floor rather than recurse")
            return
        }
    }

    // MARK: - The floor

    @Test("an error from no known family lands loudly, without the driver prefix")
    func unknownErrorFamily() {
        struct Mystery: Error {}
        let error = normalize(Mystery(), since: normalizationNow)

        guard case .unrecognized(let description) = error else {
            Issue.record("expected the loud floor, got \(error)")
            return
        }
        // The prefix marks LedgerKit's *own* invariants; a provider mystery must
        // not wear it, or triage loses the distinction the convention exists for.
        #expect(!description.hasPrefix("driver:"))
        #expect(mapping.recoverability(for: error) == .terminal)
    }

    /// Guardrail 3, asserted **structurally**: every value the driver mints for
    /// its own invariants carries §8's stable prefix. Never by matching full
    /// prose — that is ADR-001's standing rule, and the detail after the prefix
    /// is deliberately free to change.
    @Test("every driver-minted diagnostic carries the driver prefix")
    func driverDiagnosticsCarryThePrefix() {
        let inventory: [DriverDiagnostic] = [
            .sessionBusy,
            .transcriptMutatedWhileResponding,
            .nonPrefixSnapshot(.segmentRevised(id: "s0")),
            .nonPrefixSnapshot(.segmentDropped(id: "s1")),
            .nonPrefixSnapshot(.segmentsReordered(expected: "s0", found: "s1")),
            .nonPrefixSnapshot(.interiorGrowth(id: "s0")),
        ]

        for diagnostic in inventory {
            guard case .unrecognized(let description) = diagnostic.error else {
                Issue.record("a driver diagnostic must use §8's loud floor: \(diagnostic)")
                continue
            }
            #expect(description.hasPrefix("driver: "), "\(description)")
            #expect(mapping.recoverability(for: diagnostic.error) == .terminal)
        }
    }

    /// §7.3's release behaviour, spelled once so Phase 2 has something to call
    /// and this suite pins the wording's *shape* rather than its prose.
    @Test("a non-prefix snapshot names the violation it caught")
    func nonPrefixCarriesItsReason() {
        guard case .unrecognized(let description) = DriverDiagnostic.nonPrefixSnapshot(.interiorGrowth(id: "s0")).error
        else {
            Issue.record("expected the loud floor")
            return
        }
        #expect(description.hasPrefix("driver: non-prefix snapshot"))
        #expect(description.contains("s0"), "the reason is what a bug report would have to quote")
    }
}

// MARK: - Tier 2: the 27-only families

/// The families that need a 27 runtime. Gated with `.enabled(if:)` so they
/// report **skipped** on this macOS 26 host rather than passing silently, and
/// executed on the iOS 27 simulator (see ``foundationModelsAvailable``).
@Suite("Session — normalization of the 27 error families", .enabled(if: foundationModelsAvailable))
struct AppleErrorNormalizationTests {

    private let mapping = RecoverabilityMapping.default

    /// §8's coverage table, row for row — the claim that `GenerationError` is a
    /// *total* normalization of Apple's built-ins, made checkable.
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @Test("every LanguageModelError case normalizes to its §8 row")
    func builtInTaxonomy() {
        let rows: [(LanguageModelError, GenerationError)] = [
            (.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "x")),
             .contextSizeExceeded(contextSize: 4096, tokenCount: 5000)),
            (.guardrailViolation(.init(debugDescription: "x")), .guardrailViolation),
            (.refusal(.init(explanation: "no", debugDescription: "x")), .refusal),
            (.unsupportedCapability(.init(capability: .toolCalling, debugDescription: "x")),
             .unsupported(.capability)),
            (.unsupportedTranscriptContent(.init(unsupportedContent: [], debugDescription: "x")),
             .unsupported(.transcriptContent)),
            (.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "x")),
             .unsupported(.generationGuide)),
            (.unsupportedLanguageOrLocale(.init(languageCode: .english, debugDescription: "x")),
             .unsupported(.languageOrLocale)),
            (.timeout(.init(debugDescription: "x")), .transport(.timeout)),
        ]

        for (thrown, expected) in rows {
            #expect(normalize(thrown, since: normalizationNow) == expected)
        }
    }

    /// Apple's payload numbers survive, because they change what the app can
    /// *do*: `reduceContext` is a far better affordance when it can say how far
    /// over the request was (D17).
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @Test("context overflow carries Apple's two numbers into the ledger")
    func contextSizePayload() {
        let error = normalize(
            LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "x")),
            since: normalizationNow
        )

        #expect(error == .contextSizeExceeded(contextSize: 4096, tokenCount: 5000))
        #expect(mapping.recoverability(for: error) == .recoverableUpstream(.reduceContext))
    }

    /// Apple's third `Retry-After` form, converted against a supplied clock so
    /// the persisted value stays clock-independent (§8, rev 7).
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @Test("rate limiting converts Apple's resetDate instant to a duration")
    func rateLimitedResetDate() {
        let reset = normalizationNow.addingTimeInterval(90)
        let error = normalize(
            LanguageModelError.rateLimited(.init(resetDate: reset, debugDescription: "x")),
            since: normalizationNow
        )

        #expect(error == .rateLimited(retryAfter: .seconds(90)))
        #expect(mapping.recoverability(for: error) == .retryable(after: .seconds(90)))

        // Nil says "not reported", which is a different claim from "retry now".
        #expect(
            normalize(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "x")),
                      since: normalizationNow)
                == .rateLimited(retryAfter: nil)
        )
    }

    /// §8's exclusion at 27, where the two concerns are finally separate types —
    /// and both are LedgerKit defects, so both take the loud floor.
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @Test("session misuse never becomes a provider signal")
    func sessionMisuse() {
        #expect(normalize(LanguageModelSession.Error.concurrentRequests) == DriverDiagnostic.sessionBusy.error)
        #expect(normalize(LanguageModelSession.Error.transcriptMutationWhileResponding)
            == DriverDiagnostic.transcriptMutatedWhileResponding.error)
    }

    /// **rev 9:** a family §8's coverage table predates. Assets that are not on
    /// the device is `modelNotReady`, which classifies to the await-download
    /// affordance — the same landing §8 already gives PCC's `systemNotReady`.
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @Test("SystemLanguageModel.Error normalizes to an await-download affordance")
    func systemModelAssets() {
        let error = normalize(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "x")))

        #expect(error == .modelUnavailable(.modelNotReady))
        #expect(mapping.recoverability(for: error) == .recoverableUpstream(.awaitModelDownload))
    }

    /// **rev 9:** so does this one. The third row is the interesting one — §8
    /// anticipated it in prose ("if a provider family turns out to emit
    /// nil-status transients, that's a mapping override keyed on code"), so the
    /// honest landing is `terminal` with a stable code rather than a 503 the
    /// provider never sent.
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @Test("Private Cloud Compute's family normalizes by §8's existing rules")
    func privateCloudCompute() {
        let reset = normalizationNow.addingTimeInterval(600)

        #expect(normalize(PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "x")),
                          since: normalizationNow) == .transport(.connectivity))
        #expect(normalize(PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(resetDate: reset, debugDescription: "x")),
                          since: normalizationNow) == .rateLimited(retryAfter: .seconds(600)))
        #expect(normalize(PrivateCloudComputeLanguageModel.Error.serviceUnavailable(.init(debugDescription: "x")),
                          since: normalizationNow)
            == .providerFailure(status: nil, code: "serviceUnavailable", message: nil))
    }
}
