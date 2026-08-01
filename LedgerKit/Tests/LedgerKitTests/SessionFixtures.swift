import Foundation
import Testing
@testable import LedgerKit

// Shared harness for the `Session/` suites (M6). Internal for the same reason
// `StoreFixtures.swift` and `ReducerFixtures.swift` are: every phase from here
// on builds the same things the same way, and a second copy is a second thing to
// drift.

/// Whether the running OS can execute Foundation Models' 27-era API — **the
/// tier-1/tier-2 boundary, in one value** (M6-PLAN D31/D36).
///
/// Mirrors `Understudy`'s `foundationModelsAvailable`, deliberately: the two
/// packages face the same problem and a reader moving between them should not
/// have to learn two spellings.
///
/// Paired with `.enabled(if:)` on a suite, never with a bare
/// `guard #available … else { return }` — a guard turns every gated test into a
/// silent green tick on a host that cannot run it, which is exactly the kind of
/// test that certifies nothing. The trait reports **skipped**; the guard inside
/// the body is only there to satisfy the compiler's availability checking.
///
/// Phase 0's substrate spike is what makes this a real boundary rather than a
/// dormancy marker: these suites *do* run, on the iOS 27 simulator —
/// `xcodebuild test -workspace LedgerKit.xcworkspace -scheme LedgerKit
/// -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'`.
let foundationModelsAvailable: Bool = {
    if #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) { true } else { false }
}()

/// A fixed instant for normalization fixtures, so a `Retry-After` date converts
/// to a duration a test can spell.
///
/// Reusing `Log.base` rather than minting another epoch: normalization is the
/// one place a clock read is legal (§8), so the tests that exercise it should
/// still be reading the same clock every other fixture in this package does.
let normalizationNow = Log.base
