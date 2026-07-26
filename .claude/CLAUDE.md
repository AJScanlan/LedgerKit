# LedgerKit

Durable conversation-state engine for Foundation Models apps on Apple platforms (iOS/macOS 27). It is an event-sourced ledger of conversation history, a typed message-lifecycle state machine, and a reconciliation layer between durable app state and the ephemeral `LanguageModelSession`. Positioning: *"the state layer Foundation Models doesn't ship."* Pre-1.0, targeting a `0.1.0` tag before iOS 27 GA (~Sept 2026).

## Two source-of-truth documents

- **`Documentation/SPEC.md`** — the **contract** (rev 5, **ratified** 2026-07-25 at the M2 boundary). Semantics defined here are binding; type names in it are illustrative ("bikesheddable; semantics not").
- **`Documentation/ROADMAP.md`** — the **build order** (milestones M0–M9).
- **`Documentation/ADR/`** — three ADRs. **ADR-001 owns the event encoding** (tagged JSON, discriminator registry, tolerant terminals, timestamp canonicalization R-5); ADR-002 identifiers; ADR-003 persistence/GRDB. ADR-001's sentinel *strings* are explicitly non-contractual — assert on typed cases, never prose.
- **On any conflict, the spec wins and the roadmap is stale — fix the roadmap.** (The roadmap states this rule itself.)

Read the relevant spec section before implementing anything in this repo; the design is unusually load-bearing and most "obvious" simplifications are already-considered non-goals.

## Commands

There is **no `Package.swift` at the repo root.** Two independent SPM packages live in subdirectories, so every `swift` command must target one explicitly:

```bash
swift build --package-path LedgerKit
swift test  --package-path LedgerKit
swift build --package-path LedgerKitTestSupport
swift test  --package-path LedgerKitTestSupport
```

- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`) — not XCTest.
- `swift test --package-path LedgerKit --filter <TestTypeName>` — matches the **type** name, not the `@Suite("display name")`. Filtering on the display string silently matches 0 tests and reports **success**.
- ⚠️ **Ignore SourceKit "Cannot find type X in scope" / "No such module 'Testing'" in new files** — the index goes stale constantly here. `swift build` is the only ground truth; don't chase these.
- Toolchain: **Xcode 27.0 Beta 4** (build 27A5228h), **macOS 27.0 SDK**, Swift 6 language mode, strict concurrency. Packages deploy to 26 (`.macOS(.v26)`), so iOS/macOS 27 APIs need `@available` guards — they *compile* (the SDK is 27) but the dev machine runs macOS 26, so 27-only code cannot execute here. Gate such tests with `.enabled(if:)`.
- **`FoundationModels`' iOS/macOS 27 API is readable right now** — don't guess it from WWDC coverage. The authoritative interface is
  `/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`.
  This closed OQ3 and most of OQ5 at M3; several `Session/` open questions are similarly answerable by reading it.
- ⚠️ `ISO8601DateFormatter` **rounds** fractional seconds; `Date.ISO8601FormatStyle` **truncates**. Swapping to the (`Sendable`) format style shifts ~74% of timestamps 1 ms and breaks `WireDate.canonical`. The cached formatter's `nonisolated(unsafe)` is deliberate and measured (ADR-001 R-5, ~120 µs/construction) — don't "fix" it.
- `LedgerKit.xcworkspace` ties together both packages, the `Projection` demo app, `Documentation/`, and a playground. Build the demo app from the workspace in Xcode (scheme `Projection`).

## Architecture

**Boundary rule (SPEC §2): Apple owns inference; LedgerKit owns durable state.** LedgerKit consumes `any LanguageModel` / `LanguageModelSession` and never wraps or re-exports them. Everything in the left column of the §2 boundary map (inference protocol, providers, in-session transcript/compaction, tool execution) is a non-goal *forever*, not just for v0.1.

Three products, one workspace:

- **`LedgerKit/`** — the library. Source tree is scaffolded but mostly empty, filled per milestone:
  - `Core/` — event log + derived-state types (SPEC §6.1–6.2). This is **wire format = API forever**; adding an event kind is a permanent commitment.
  - `Reduce/` — the pure reducer, `fold → classify` (§6.3, invariants I1–I7). **The load-bearing wall:** `nonisolated`, deterministic, no clocks, no I/O. Persistence, the store, the projection, and the demo are all downstream of a correct fold.
    - **Never let `Dictionary` iteration order reach output** — Swift's hasher seed varies per process, so a leak breaks I1 by passing locally and flaking in CI. Iterate ordered arrays; dictionaries are for keyed lookup.
    - **No `!`, `precondition`, or recursion over tree depth** — I2 forbids trapping *and* hanging, and tree depth tracks message count in a linear conversation.
    - **Quarantine is data, not error handling.** Nothing in the fold throws: an event already happened, so the fold can only decide what it means. Wanting `throws` is the smell.
    - Two parallel state enums, deliberately: internal `FoldedMessageState` (4 cases, `Codable`, = the snapshot schema) vs public `MessageState` (5 cases, **not** `Codable`). `.open ⇒ .interrupted` happens only in `classify`; `.streaming` only in M7's overlay.
    - Snapshot `Codable` is **disposable** (discard-on-mismatch, no migrations), so widening folded types is free. The event `Payload` encoding is **permanent**. Don't conflate them.
  - `Store/` — SQLite persistence + snapshots + index, the `ConversationStore` actor, and the turn verbs (§9, §6.5, §11).
  - `Session/` — the `GenerationDriver`, the one OS-coupled module (§7). **All iOS-27-beta risk (the ⚠️ / OQ1–9 items) is isolated here and nowhere else.**
  - `Projection/` — the `@MainActor @Observable` read side + `overlay_live` (§6.2, §7.4).
- **`LedgerKitTestSupport/`** — ships `ScriptedLanguageModel`, a deterministic `LanguageModel` test double. A separate product on purpose ("the gateway drug" — useful to any Foundation Models app, and lets the whole library test with zero network and zero Apple Intelligence eligibility).
- **`Projection/`** (top-level Xcode app) — the demo (kill-mid-stream recovery + one-line provider swap).

⚠️ **Naming collision to keep straight:** the top-level `Projection/` *app* is distinct from `LedgerKit/Sources/LedgerKit/Projection/` (the internal observable-projection layer). Older notes may call the demo app "Scroll" — it is `Projection`.

Reducer test harness (`Log` builder, `Fix` identifiers, `reasons` accessors) lives in `Tests/LedgerKitTests/ReducerFixtures.swift` at **internal** scope — reuse it rather than rebuilding. A same-named `private enum` in another test file in the module will collide with it.

## Design tenets (constrain every change — SPEC §3)

1. **Illegal states unrepresentable** — closed enums; never an `isLoading: Bool` beside an `error: Error?`. A message cannot be simultaneously streaming and failed.
2. **Event-sourced: the log is the truth** — state is a deterministic fold over an append-only log. Snapshots, the conversation index, and the observable projection are all derived, rebuildable, and deletable.
3. **The inference boundary is Apple's** — never wrap or re-abstract `LanguageModelSession` / `any LanguageModel`.
4. **Signals cannot be skipped** — every generation ends in exactly one terminal outcome (completed/failed/cancelled) or is derivably `.interrupted`.
5. **Test doubles are first-class** — see `ScriptedLanguageModel`.
6. **Strict concurrency clean** — no `@unchecked Sendable` in public API; the reducer is pure and isolated from UI.

## Working discipline

- **Build order is deliberate:** pure core (M1–M5) is fully built and tested before the beta-coupled `Session/` seam (M6). M1–M5 verify on any Mac; only M6 re-opens per iOS 27 beta. Don't pull `Session/` work forward.
- **Never cut, even under time pressure:** invariants I1–I7 and property tests P1–P3, interruption recovery, and `ScriptedLanguageModel`.
- **Testing *is* the product differentiation:** golden-log fixtures (snapshot-tested), hostile fixtures mirroring the §6.6 quarantine table row-for-row, crash-point fuzzing (truncate every fixture at every prefix — "the single highest-value suite"), and property tests P1–P3.
- **Persistence backend is deliberately undecided** (GRDB vs. raw sqlite3, behind a small protocol) — don't bikeshed it early. **SwiftData is explicitly the wrong shape** for an append-only log; don't reach for it.
- **Status:** M0–M3 done and **audited**, **196 tests green** (175 `LedgerKit` + 21 `LedgerKitTestSupport`), **SPEC rev 6 ratified** (2026-07-26; amendments now open rev 7). `Core/` and `Reduce/` are complete. Public reduction entry point is `Conversation(reducing:loadedFrom:mapping:)` — there is no top-level `reduce`. `Store/Persistence.swift` is the *seam only* — no GRDB wiring; its `events` verb returns `[LoadedEvent]`, which is what makes M4's two-stage decode implementable above the seam. `Session/` and `Projection/` are still empty. **Next: M4** (SQLite store, snapshots, index).
- **M3 landed** (see `Documentation/M3-PLAN.md` for the decision log D1–D12 and per-phase audit notes):
  - **Test harness.** `Corpus.swift` is the fixture registry every sweep iterates — add a fixture there and it inherits truncation, interior-gap, compound and P3 coverage for free. `InvariantChecks.swift` holds the two predicates (`invariantProblems(in: FoldedState)` and the bridging `(in:foldedFrom:)`, which asserts the `.open ⇒ .interrupted` correspondence). `InvariantCheckTests.swift` tests *the predicates* — don't delete it; a vacuous predicate would silently gut the fuzz suite.
  - **Crash-fuzzing is exhaustive, not randomised** — fixtures are ≤22 rows, so there is no seed to manage and failures reproduce by re-running.
  - **On-disk corpus** in `Tests/LedgerKitTests/Corpus/`: `dev/` regenerable via `LEDGERKIT_RECORD=1 swift test --package-path LedgerKit`, `wire/` hand-authored and **never** regenerated, `frozen/` empty until 0.1.0 and a diff there is always a regression. Read `Corpus/README.md` before touching any of it. Dumps render `FoldedState`, *not* `Conversation`, so §8 mapping changes cannot break frozen fixtures.
  - **`LedgerKitTestSupport`** ships `Script` / `Script.Step` / `Cue` / `ScriptExhaustion` (platform-agnostic, 26+) and `ScriptedLanguageModel` conforming to Apple's real protocols (`@available(macOS 27)`). It **must not** depend on LedgerKit — LedgerKit's *test* target imports it at M5/M6. Its product name is provisional (SPEC §10.1).
- **Mutation-test anything whose failure mode is subtle.** Inject a deliberate breakage, confirm the suite catches it, revert. It has repeatedly found holes that looked like coverage — most sharply in Phase 4, where deleting the script player's between-step cancellation check left the entire suite green, because every *suspending* step already throws on cancellation by itself. Suspension points mask each other.

## Conventions & workflow preferences

- **Test rhythm**
  - Test Driven Development
  - Do not mark a milestone done without all tests passing
  - Reducer/spec work goes: audit → propose SPEC amendment → get approval → implement. **Rev 5 is ratified, so amendments now open rev 6** (new appendix, new `Changes from rev 5:` header) rather than editing rev 5 in place.
- **Learn-by-doing handoffs**
  - For dense, design-heavy code: Claude writes the scaffolding and leaves one branch as `TODO(human)` with a precise contract, plus tests that fail until it is implemented. Offer this; don't impose it.
- **Documentation**
  - Update `ROADMAP.md` freely if it's stale
  - Do not edit `SPEC.md` without asking
- **Milestone discipline**
  - Prioritize milestone order, but exploratory spikes allowed when valuable
- **Commits/PRs**
  - Do not commit without asking
- **Code style**
  - Follow Swift Package idioms and best practices
  - Structure types in the following order
    - Public/Internal/Private inner types
    - Public/Internal/Private static properties
    - Public/Internal/Private properties
    - Init/Deinit
    - Public/Internal/Private static functions
    - Public/Internal/Private functions