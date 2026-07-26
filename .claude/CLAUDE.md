# LedgerKit

Durable conversation-state engine for Foundation Models apps on Apple platforms (iOS/macOS 27). It is an event-sourced ledger of conversation history, a typed message-lifecycle state machine, and a reconciliation layer between durable app state and the ephemeral `LanguageModelSession`. Positioning: *"the state layer Foundation Models doesn't ship."* Pre-1.0, targeting a `0.1.0` tag before iOS 27 GA (~Sept 2026).

## Two source-of-truth documents

- **`Documentation/SPEC.md`** — the **contract** (**rev 8 open** — post-M4-audit amendments, Appendix F; rev 7 ratified 2026-07-26 at the M4 boundary). Semantics defined here are binding; type names in it are illustrative ("bikesheddable; semantics not").
- **`Documentation/ROADMAP.md`** — the **build order** (milestones M0–M9).
- **`Documentation/ADR/`** — three ADRs. **ADR-001 owns the event encoding** (tagged JSON, discriminator registry, tolerant terminals, timestamp canonicalization R-5); ADR-002 identifiers; ADR-003 persistence/GRDB. ADR-001's sentinel *strings* are explicitly non-contractual — assert on typed cases, never prose.
- **On any conflict, the spec wins and the roadmap is stale — fix the roadmap.** (The roadmap states this rule itself.)

Read the relevant spec section before implementing anything in this repo; the design is unusually load-bearing and most "obvious" simplifications are already-considered non-goals.

## Commands

There is **no `Package.swift` at the repo root.** Two independent SPM packages live in subdirectories, so every `swift` command must target one explicitly:

```bash
swift build --package-path LedgerKit
swift test  --package-path LedgerKit
swift build --package-path Understudy
swift test  --package-path Understudy
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
  - `Store/` — SQLite persistence + snapshots + index, the `ConversationStore` actor, and the turn verbs (§9, §6.5, §11). **GRDB is wired as of M4 Phase 1** (ADR-003 Accepted):
    - `SQLitePersistenceStore` is the only place GRDB appears and the only place bytes are decoded. **GRDB must never leak** — not in signatures, not in thrown errors, not re-exported. `PersistenceStore`, `Snapshot` and the store class are all internal; consumers see only `PersistenceConfiguration`.
    - **Three `STRICT` tables.** `events.payload` is **TEXT** (readable via `sqlite3` and `json1` — D19); `snapshots.payload` is BLOB. `sequence` and `schema_version` are **column-only**; `conversation_id` is deliberately in column *and* blob, which is what §6.6 row 4 checks.
    - `LedgerSchema` holds **two** versions that fail in opposite directions: `payloadVersion` (wire; a bump selects an upcaster, invalidates nothing) and `reducerVersion` (snapshots; a bump discards them, migrates nothing). Don't merge them.
    - `WireJSON` (in `Core/WireCoding.swift`) is the **one** production encoder — `[.sortedKeys, .withoutEscapingSlashes]`, compact. Anything asserting literal bytes must go through it, or it pins bytes nobody writes. Corpus *files* pretty-print; that's the file format, not the store's.
    - ⚠️ **`append` asserts timestamps are already canonical; it must never canonicalize them.** Repairing at write time would give every event two identities depending on whether it had been to disk — the bug class P1/P3 exist to catch (ADR-001 R-5).
    - Index maintenance skips `deltaAppended` **only**, via an exhaustive `Payload.updatesIndex`, so a new payload kind can't be added without deciding its side of the line.
    - **Snapshots** (`Store/Snapshots.swift`, M4 Phase 3): `Snapshot(encoding:upTo:)` / `snapshot.foldedState` / `store.foldedState(of:)` / `store.saveSnapshot(of:upTo:)`. All **above the seam** — `foldedState(of:)` is a protocol *extension*, not a seventh verb (ADR-003 rule 4 caps requirements at six).
      - `foldedState` returns `nil` on **four** conditions, all one branch: either version mismatched, payload undecodable, payload names another conversation (the snapshot analogue of §6.6 row 4), or `upToSequence < 1`. Never fatal — worst case is the replay it was avoiding.
      - ⚠️ **Resume reads from `upToSequence + 1` and passes `upToSequence` as `after:`.** Off-by-one re-reads the last row, and `deltaAppended`/`toolInvocationRecorded` are the two non-idempotent kinds (§6.6 ordering) — it silently doubles text. Losing `after:` blinds gap detection across the checkpoint boundary. Both are mutation-tested.
      - A snapshot **read** failure is swallowed (truth is the log); an `events` failure propagates (that *is* the truth failing).
  - `Session/` — the `GenerationDriver`, the one OS-coupled module (§7). **All iOS-27-beta risk (the ⚠️ / OQ1–9 items) is isolated here and nowhere else.**
  - `Projection/` — the `@MainActor @Observable` read side + `overlay_live` (§6.2, §7.4).
- **`Understudy/`** — ships `ScriptedLanguageModel`, a deterministic `LanguageModel` test double. A separate product on purpose ("the gateway drug" — useful to any Foundation Models app, and lets the whole library test with zero network and zero Apple Intelligence eligibility). Named `LedgerKitTestSupport` through M3; renamed at M4 Phase 0 (M4-PLAN D14), so older notes and SPEC rev ≤6 still say the old name.
- **`Projection/`** (top-level Xcode app) — the demo (kill-mid-stream recovery + one-line provider swap).

⚠️ **Naming collision to keep straight:** the top-level `Projection/` *app* is distinct from `LedgerKit/Sources/LedgerKit/Projection/` (the internal observable-projection layer). Older notes may call the demo app "Scroll" — it is `Projection`.

Reducer test harness (`Log` builder, `Fix` identifiers, `reasons` accessors) lives in `Tests/LedgerKitTests/ReducerFixtures.swift` at **internal** scope — reuse it rather than rebuilding. A same-named `private enum` in another test file in the module will collide with it. Since M4 it also carries `Log.records` (the wire records `append` takes) and `Log.timestampsAreCanonical`, so the store suites replay exactly the logs the reducer suites fold — a disagreement between the two layers has nowhere to hide.

Three more shared test-side landmarks, all added at **M4 Phase 4** — reuse them rather than rebuilding:

- **`Wire` (in `WireFormatTests.swift`) is now `internal`, not file-private.** It is the module's *only* exhaustive inventory of the wire surface (`allKinds`, `allOutcomes`, `allErrors`, `allToolRecords`), and the registry test depends on that: because every case is named there, **deleting an enum case is a compile error**. Never fork a second inventory; extend this one.
- **`Registry/tags.json` + `RegistryTests.swift`** — the discriminator registry (ADR-001 D-3, now closed). Every tag and field key at every level, plus the reserved table, checked against what the codecs encode in *both* directions. Adding a payload kind or a field key means editing this file, ADR-001's R-3 table, and landing a corpus fixture — in the same change. `Registry/` is a second test resource beside `Corpus/` (see `Package.swift`), hand-edited and never recorded.
- **`ProjectionChecks.swift`** — P2's predicate plus `LiveSet` / `LiveOverlay` / `identityOverlay`. **The overlay is a parameter**, which is the whole of "P2 scaffolding": M7 passes in the real `overlay_live` and changes no assertion. `referenceOverlay` there is a *control* (it proves the predicate is satisfiable with a non-empty live set) — do not mistake it for the production overlay or promote it out of the test target.

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
- **Persistence backend is decided: GRDB** (ADR-003 Accepted, wired at M4) behind the six-verb internal seam; raw sqlite3 remains the §12 cut-line fallback, priced in days. **SwiftData is explicitly the wrong shape** for an append-only log; don't reach for it.
- **Status:** M0–**M4** done and **audited**, **266 tests green** (245 `LedgerKit` + 21 `Understudy`), **SPEC rev 8 open** (2026-07-27, Appendix F: `stopReason` provenance + illustrative-name refresh; rev 7 ratified 2026-07-26 at the M4 boundary). **ADR-003 Accepted; ADR-001 D-1/D-2/D-3 all closed** — that ADR has no open questions left. **Next: M5.** Cold-open criterion met: 10,004 events → 3 rows replayed. `Core/` and `Reduce/` are complete. Public reduction entry point is `Conversation(reducing:loadedFrom:mapping:)` — there is no top-level `reduce`. `Store/Persistence.swift` is the seam *declaration* (the six verbs, `PersistenceConfiguration`, `Snapshot`); `Store/SQLitePersistenceStore.swift` is its one GRDB conformance. The `events` verb returns `[LoadedEvent]`, which is what makes the two-stage decode implementable above the seam. `Session/` and `Projection/` are still empty. M4's plan and decision log (D13–D20) are in `Documentation/M4-PLAN.md`; **M5** (the `ConversationStore` actor + turn verbs) is the next milestone, and M4-PLAN §7 lists five explicit handoffs to it.
- **M4 is done** (plan, decision log D13–D20, and per-phase audit notes in `Documentation/M4-PLAN.md`):
  - ✅ **M4 boundary audit applied (2026-07-26), all breaking while still free.** `LedgerEvent.Payload`'s generation/message values are now **labelled** (`generationStarted(generation:message:parent:model:)` etc. — wire-neutral; tags live in `Kind`, keys in `CodingKeys`); `QuarantineReason.unknownPayloadKind` → **`undecodablePayload(kind:)`** and `LoadedEvent.DecodeFailure.payloadKind` → **`.payload(kind:)`** (rev 7's widened row 2 made the old names false on the known-kind half; **`reducerVersion` bumped to 2** since the synthesized snapshot encoding moved); `IDGenerator` vends via **`make*` methods** (`makeEventID()` — they mutate; getter-shaped names read as pure) and its init label is `randomSource:`; `PersistenceConfiguration.sqlite(at:)` (was `url:`); `Understudy`: `Script.Step.wait(until:)` (was `waitFor`), `ScriptExhausted.scriptCount`/`.requestNumber`, `responseCount` dropped (`requests.count` is the API). `StopInfo.stopReason`/`resolvedModelID` verified to have **no dedicated 27-SDK surface** — per-provider convention, expect nil on-device.
  - ✅ **Phase 0 is done** (two commits: the `Understudy` rename, then the breaking-surface pass). The resulting API rules, which the rest of M4 must not undo:
    - **Derived state is constructible only by reducing a log.** `Message.init`, `Conversation.init` (memberwise), `QuarantinedEvent.init` and `ConversationSummary.init` are **internal**; `Conversation(reducing:loadedFrom:mapping:)` is the only public way in. `MessageContent.init` stays public *deliberately* — a string wrapper has no invariant to violate, and previews need it. Don't "fix" either half.
    - `Content` is now **`MessageContent`**. `MessageState.failed(partial:error:recoverability:)` is **labelled**; internal `FoldedMessageState.failed` is deliberately **not** (two payloads, reducer-internal).
    - `GenerationError` has a **`CustomStringConvertible`** whose prose is non-contractual (ADR-001) — assert structure and payload propagation, never wording. `ErrorDiagnosticsTests` in `WireFormatTests.swift` is the pattern; it lives there because `Wire.allErrors` is the module's only exhaustive taxonomy inventory.
    - **`PersistenceConfiguration` and `ScriptExhaustion` are structs with static factories over an internal enum** — D12's rule ("enums for values consumers destructure, structs-with-factories for instructions consumers construct"). New config-shaped types follow this; M4's wiring switches on the internal `.backend` / `.policy`.
    - ⚠️ **The Playground hand-builds a tree and needs `@testable`.** Converting it to the `Conversation(reducing:)` example is an open follow-up, deliberately deferred: playgrounds are invisible to `swift build`, so it cannot be compile-verified from the CLI. Fix it in Xcode or at M7.
  - ✅ **SPEC rev 7 is ratified** (2026-07-26, at the M4 boundary; Appendix E). It closed **OQ1/2/4/6/7/8/9** — seven of nine, all by *reading* the SDK rather than running it — landed D17's wire change, widened §6.6 row 2, and recorded what M4 built (§9's TEXT payload, the four-way snapshot discard, P1 as a store property, exhaustive-not-randomized sweeps, the enforced registry). **Four empirical residues remain, all M6's**, listed at the head of §14.
  - ⚠️ **Two SDK facts now *in* the spec** (they used to contradict its prose): the provider channel has `replaceTextSegment`, so §7.3's plain-text prefix property is provider behavior rather than an API guarantee — the driver's fail-loud path is therefore load-bearing, not a can't-happen assertion; and the busy-session error is the typed `LanguageModelSession.Error.concurrentRequests`. The iOS 26 enum that conflated it with `rateLimited` is **deprecated, not removed**, so normalization must still recognize both families (§8).
  - ⚠️ **A fact-table row was wrong, and the correction is worth knowing before M6 reads that table again:** M4-PLAN §2 claimed `Transcript.Entry` gained a seventh case, `attachment`. It did not — `Entry` still has six kinds; **`Transcript.Segment`** is what grew (to `text`, `structure`, `attachment`, `custom`). The cited line belonged to the neighbouring declaration. M4-PLAN §2 now carries the correction, the confirmed citation list, and the generalizable lesson: **re-read a citation before anything downstream depends on it.**
- **M3 landed** (see `Documentation/M3-PLAN.md` for the decision log D1–D12 and per-phase audit notes):
  - **Test harness.** `Corpus.swift` is the fixture registry every sweep iterates — add a fixture there and it inherits truncation, interior-gap, compound and P3 coverage for free. `InvariantChecks.swift` holds the two predicates (`invariantProblems(in: FoldedState)` and the bridging `(in:foldedFrom:)`, which asserts the `.open ⇒ .interrupted` correspondence). `InvariantCheckTests.swift` tests *the predicates* — don't delete it; a vacuous predicate would silently gut the fuzz suite.
  - **Crash-fuzzing is exhaustive, not randomised** — fixtures are ≤22 rows, so there is no seed to manage and failures reproduce by re-running.
  - **On-disk corpus** in `Tests/LedgerKitTests/Corpus/`: `dev/` regenerable via `LEDGERKIT_RECORD=1 swift test --package-path LedgerKit`, `wire/` hand-authored and **never** regenerated, `frozen/` empty until 0.1.0 and a diff there is always a regression. Read `Corpus/README.md` before touching any of it. Dumps render `FoldedState`, *not* `Conversation`, so §8 mapping changes cannot break frozen fixtures.
    - **Since M4 Phase 2, damaged rows are derived from bytes, not synthesized.** `Log.unknownPayloadKind(_:)` / `Log.corruptRow(_:)` build JSON and run it through `SQLitePersistenceStore.load` — the production loader — so a fixture's `raw` row *is* the input the fold saw. `rich` and `hostile` are on disk because of it. `Log.undecodable(_:)` still synthesizes and is still right for **fold-level** unit tests, but `CorpusDocument(_:)` refuses to serialize one.
    - Consequence to keep in mind: **the corpus now depends on the loader.** A loader change can break in-memory residue expectations, which is the coverage working as intended, not a broken test.
    - `Log.isStoreReplayable` states which fixtures can round-trip through the store (gapless, single-stream, no byte-built rows) — three are legitimately excluded. Don't hard-code fixture names in its place.
  - **`Understudy`** ships `Script` / `Script.Step` / `Cue` / `ScriptExhaustion` (platform-agnostic, 26+) and `ScriptedLanguageModel` conforming to Apple's real protocols (`@available(macOS 27)`). It **must not** depend on LedgerKit — LedgerKit's *test* target imports it at M5/M6. The name is settled: SPEC §10.1's provisional-name clause **resolved in rev 7**.
- **Mutation-test anything whose failure mode is subtle.** Inject a deliberate breakage, confirm the suite catches it, revert. It has repeatedly found holes that looked like coverage — most sharply in Phase 4, where deleting the script player's between-step cancellation check left the entire suite green, because every *suspending* step already throws on cancellation by itself. Suspension points mask each other.

## Conventions & workflow preferences

- **Test rhythm**
  - Test Driven Development
  - Do not mark a milestone done without all tests passing
  - Reducer/spec work goes: audit → propose SPEC amendment → get approval → implement. **Rev 8 is open** (Appendix F); further amendments extend it until it ratifies at the next milestone boundary, then rev 9 opens with a new appendix. The drafting pattern that worked at rev 7: write the proposed edits to a scratch draft, get sign-off item by item, *then* touch `SPEC.md`.
  - **When a SPEC revision lands, sweep `Sources/**` doc comments for claims it just made stale** — ⚠️ markers, OQ numbers, and quoted spec text ("both forms", "randomized"). Rev 7 left three behind; the M4 audit caught them. The spec-side self-contradiction sweep already exists (M4-PLAN Phase 5) — this is its code-side half.
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