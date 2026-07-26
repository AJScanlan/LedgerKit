import Foundation
import Testing
@testable import LedgerKit

/// §8's default table, asserted row for row. Written as explicit pairs rather
/// than computed so this suite can be diffed against the spec table — §8 says the
/// mapping is "expected to churn," and a golden that reads like the source
/// document is what makes churn reviewable.
@Suite("RecoverabilityMapping — §8 default table")
struct RecoverabilityMappingDefaultTests {

    private static let rows: [(GenerationError, Recoverability)] = [
        (.modelUnavailable(.deviceNotEligible), .terminal),
        (.modelUnavailable(.appleIntelligenceNotEnabled), .recoverableUpstream(.enableAppleIntelligence)),
        (.modelUnavailable(.modelNotReady), .recoverableUpstream(.awaitModelDownload)),
        (.contextSizeExceeded, .recoverableUpstream(.reduceContext)),
        (.guardrailViolation, .terminal),
        (.refusal, .terminal),
        (.unsupported(.capability), .terminal),
        (.unsupported(.transcriptContent), .terminal),
        (.unsupported(.generationGuide), .terminal),
        (.unsupported(.languageOrLocale), .terminal),
        (.rateLimited(retryAfter: .seconds(30)), .retryable(after: .seconds(30))),
        (.rateLimited(retryAfter: nil), .retryable(after: nil)),
        (.transport(.timeout), .retryable(after: nil)),
        (.transport(.connectivity), .retryable(after: nil)),
        (.transport(.tls), .retryable(after: nil)),
        (.providerFailure(status: 500, code: nil, message: nil), .retryable(after: nil)),
        (.providerFailure(status: 503, code: nil, message: nil), .retryable(after: nil)),
        (.providerFailure(status: 401, code: nil, message: nil), .recoverableUpstream(.reauthenticate)),
        (.providerFailure(status: 403, code: nil, message: nil), .recoverableUpstream(.reauthenticate)),
        (.providerFailure(status: 407, code: nil, message: nil), .recoverableUpstream(.reauthenticate)),
        (.providerFailure(status: 429, code: nil, message: nil), .retryable(after: nil)),
        (.providerFailure(status: 400, code: nil, message: nil), .terminal),
        (.providerFailure(status: 404, code: nil, message: nil), .terminal),
        (.providerFailure(status: 422, code: nil, message: nil), .terminal),
        (.providerFailure(status: nil, code: "overloaded_error", message: nil), .terminal),
        (.providerFailure(status: nil, code: nil, message: nil), .terminal),
        (.unrecognized(description: "mystery"), .terminal),
    ]

    @Test("each row classifies as §8 says", arguments: rows)
    func defaultRow(_ error: GenerationError, _ expected: Recoverability) {
        #expect(RecoverabilityMapping.default.recoverability(for: error) == expected)
    }

    @Test("rateLimited passes the error's OWN duration through — no slot to override")
    func rateLimitedPassesDurationThrough() {
        // Normalization already made the duration clock-independent (§8), so
        // classification just forwards it; display math is
        // `terminalTimestamp + retryAfter`.
        for duration in [Duration.seconds(1), .seconds(120), .milliseconds(500)] {
            #expect(
                RecoverabilityMapping.default.recoverability(for: .rateLimited(retryAfter: duration))
                    == .retryable(after: duration)
            )
        }
    }

    @Test("429 is lifted before the general 4xx row — order matters")
    func rateLimitStatusBeatsClientError() {
        // 429 IS a 4xx. Falling through to `providerClientError` would classify a
        // rate limit as terminal, which is the bug this precedence prevents.
        let mapping = RecoverabilityMapping.default
        #expect(mapping.recoverability(for: .providerFailure(status: 429, code: nil, message: nil))
            == .retryable(after: nil))
        #expect(mapping.recoverability(for: .providerFailure(status: 400, code: nil, message: nil))
            == .terminal)
    }

    @Test("auth statuses are lifted before the general 4xx row")
    func authStatusBeatsClientError() {
        for status in [401, 403, 407] {
            #expect(
                RecoverabilityMapping.default
                    .recoverability(for: .providerFailure(status: status, code: nil, message: nil))
                    == .recoverableUpstream(.reauthenticate),
                "status \(status)"
            )
        }
    }

    @Test("message NEVER participates in classification (§8)")
    func messageIsNotAClassificationInput() {
        let mapping = RecoverabilityMapping.default
        let messages: [String?] = [nil, "", "retry later", "permanent failure, do not retry"]
        let classified = messages.map {
            mapping.recoverability(for: .providerFailure(status: 500, code: nil, message: $0))
        }
        #expect(
            classified.allSatisfy { $0 == classified[0] },
            "message text changed the verdict: \(classified)"
        )
    }

    @Test("a status outside 4xx/5xx takes the loud floor — §8 enumerates neither")
    func statusOutsideEnumeratedClasses() {
        // Not a spec row: a failure reporting 2xx/3xx is malformed rather than
        // meaningful, so it lands on the same safe default as an unclassifiable one.
        for status in [200, 302, 100, 600] {
            #expect(
                RecoverabilityMapping.default
                    .recoverability(for: .providerFailure(status: status, code: nil, message: nil))
                    == .terminal,
                "status \(status)"
            )
        }
    }
}

@Suite("RecoverabilityMapping — overrides and identity")
struct RecoverabilityMappingOverrideTests {

    @Test("per-case override changes only that case")
    func perCaseOverride() {
        var mapping = RecoverabilityMapping.default
        mapping.guardrailViolation = .retryable(after: nil)

        #expect(mapping.recoverability(for: .guardrailViolation) == .retryable(after: nil))
        #expect(mapping.recoverability(for: .contextSizeExceeded) == .recoverableUpstream(.reduceContext))
        #expect(mapping.recoverability(for: .unrecognized(description: "x")) == .terminal)
        #expect(
            mapping.recoverability(for: .refusal) == .terminal,
            "refusal and guardrailViolation are separate slots — that is why they are separate cases"
        )
    }

    @Test("providerCodes supplies §8's per-provider table; unmatched falls to its own slot")
    func providerCodeTable() {
        var mapping = RecoverabilityMapping.default
        mapping.providerCodes = ["overloaded_error": .retryable(after: .seconds(5))]
        mapping.providerUnmatchedCode = .recoverableUpstream(.reauthenticate)

        #expect(mapping.recoverability(for: .providerFailure(status: nil, code: "overloaded_error", message: nil))
            == .retryable(after: .seconds(5)))
        #expect(mapping.recoverability(for: .providerFailure(status: nil, code: "who_knows", message: nil))
            == .recoverableUpstream(.reauthenticate))
        #expect(mapping.recoverability(for: .providerFailure(status: nil, code: nil, message: nil))
            == .terminal, "no code at all is a different row from an unmatched code")
    }

    @Test("providerCodes is consulted ONLY when there is no HTTP status (§8)")
    func statusWinsOverCode() {
        var mapping = RecoverabilityMapping.default
        mapping.providerCodes = ["overloaded_error": .recoverableUpstream(.reauthenticate)]
        // A status exists, so the status class decides and the code is ignored.
        #expect(mapping.recoverability(for: .providerFailure(status: 500, code: "overloaded_error", message: nil))
            == .retryable(after: nil))
    }

    @Test("the mapping is Equatable — which is what makes I1's second half assertable")
    func equatable() {
        var changed = RecoverabilityMapping.default
        #expect(changed == .default)
        changed.guardrailViolation = .retryable(after: nil)
        #expect(changed != .default)

        var codes = RecoverabilityMapping.default
        codes.providerCodes = ["x": .terminal]
        #expect(codes != .default)
    }
}
