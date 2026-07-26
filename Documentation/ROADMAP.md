# LedgerKit v0.1 — Build Roadmap

**Companion to:** [SPEC.md](./SPEC.md) — **rev 7, ratified 2026-07-26 at the M4 boundary**; subsequent amendments open rev 8. (Rev 6: M3 boundary, same day; rev 5: 2026-07-25, M2 boundary.)
**Target:** tagged `0.1.0` before iOS 27 GA (~Sept 2026). Estimate from spec §12: **4–6 weeks part-time**, assuming the ⚠️ beta verifications hold.
**Sequencing strategy:** *pure core first* — build and fully test everything platform-agnostic (§6) before touching the beta-coupled session seam (§7).

> This document is the **build order**. The spec is the **contract**. Where they ever disagree, the spec wins and this file is stale — fix it.

---

## Why this order

The spec has a clean dependency spine, and the roadmap just walks it:

```
Core types (§6.1–6.2)        pure, no deps            ─┐
        │                                              │  ZERO beta risk.
Reducer: fold → classify (§6.3, I1–I7, §6.6)  pure    │  Fully testable with
        │                                              │  golden logs + Scripted
Test corpus (§10) + ScriptedLanguageModel (§10.1)      │  model. Build & harden
        │                                             ─┘  before any iOS 27 beta.
SQLite store + snapshots + index (§9)         I/O, still no FM
        │
ConversationStore actor + verbs (§6.5, §11)   concurrency, still no FM
        │
GenerationDriver (§7)  ◄──── ALL beta risk lives here, and only here
        │                     (OQ1–9 are closed as of rev 7; four behavioural residues remain)
        │
Observable projection + overlay_live (§6.2, §7.4, §11)
        │
Projection demo app (§13 DoD-1/2)
        │
README + ADR-001 + tag (§13 DoD-3/4/5)
```

Two consequences worth internalizing:

1. **The reducer is the load-bearing wall.** Persistence, the store, the projection, and the demo are all downstream of a correct `fold`. Get I1–I7 right and everything above stands; get them wrong and no amount of UI polish saves it. This is why M2–M3 are the true center of gravity, not the demo.
2. **Beta churn is contained to M6.** Everything M1–M5 is verifiable on an Intel Mac with zero Apple Intelligence eligibility. When betas drop through August, only the driver milestone re-opens (spec §12: "expect to repeat the API-verification evening per beta").

**Never cut** (spec §12): I1–I7 **and** P1–P3 tests, interruption recovery, `ScriptedLanguageModel`. These are load-bearing; the demo polish is not.

---

## Milestones

Each milestone lists the spec goals it satisfies (G1–G9), its exit criteria (what "done" means), and its beta exposure.

### ~~M0 — Reset the scaffolding & package skeleton~~
The pre-spec `Data/Models/` stubs — `ChatEvent.swift` (linear `tokenAppended` events) and a `Message.swift` with a flat 3-case status, no branching/interruption/recoverability — contradicted §6 and were deleted rather than extended. Both files are gone; the paths no longer resolve.

~~- Delete the stub types; establish the source tree layout (`Core/`, `Reduce/`, `Store/`, `Session/`, `Projection/`).~~

~~- Split the package into two products: `LedgerKit` and `LedgerKitTestSupport` (the Scripted model ships separately — spec §10.1, "the gateway drug").~~

**Exit:** empty package builds under Swift 6 strict concurrency; two products resolve; stubs gone.
**Beta risk:** none.

### ~~M1 — Core types (pure, wire format)~~

The event log and derived-state vocabulary. This is API surface *forever* (§6.1) — get the shapes right, names are bikesheddable.

~~- `EventID` (UUIDv7 generator — ours, Foundation only mints v4, §6.1), `ConversationID`, `MessageID`, `GenerationID`, `Int64` sequence.~~

~~- `LedgerEvent` + the ten-kind `Payload` enum, `Outcome`, `ToolRecord`, `StopInfo`, `ModelDescriptor` (§6.1).~~

~~- Derived state: `Conversation`, `Message`, `MessageState` (5 cases), `Content` (struct, not `String` — §6.2 additive-headroom), `QuarantinedEvent`.~~ *(plus `MessageTree`'s read API: optional subscript, `children(of:)`, exclusive `siblings(of:)` with virtual-root support, `Conversation.activeMessages`)*

~~- `GenerationError`, `Recoverability`, `RequiredAction` (§8) — note `Recoverability` is **not** `Codable` (derived, never persisted).~~

~~- Tagged-JSON `Codable` conformances with a discriminator registry (ADR-001 territory — draft the ADR here even if it's ratified at M9).~~ *(conformances landed; ADR-001 drafted with R-1–R-4 recorded, D-1–D-3 open for M9)*

~~- Decide the persistence dependency (GRDB) behind a small protocol — but don't wire it yet (§9: "decide at implementation, don't bikeshed now").~~ *(seam landed as `Store/Persistence.swift` — six verbs, `PersistenceConfiguration`, `Snapshot`, `ConversationSummary`; ADR-003 drafted, ratifies at M4 when wired)*

*(Also landed, unplanned: **ADR-002** — identifier design, accepted; four distinct types over a closed `LedgerIdentifier` protocol, UUIDv7 for all four. M9's "ADR-001" DoD-5 item is now three ADRs — see [ADR/README.md](./ADR/README.md).)*

**Satisfies:** foundation for G1–G9.
**Exit:** every type round-trips through `Codable`; `MessageState`/`Recoverability` deliberately have no persistence path; a `swift build` is clean. ✅ *38 tests green.*
**Beta risk:** low — `StopInfo`/`ModelDescriptor`/`GenerationError` field names are ⚠️ (OQ5, OQ8, §7.7) but the *shapes* are stable; pin field names at M6.

### ~~M2 — The reducer: `fold → classify` (the heart)~~
Pure functions over `Sendable` values, `nonisolated`, no clocks, no I/O (§6.3, §11 isolation sketch).

- ~~`fold(log) -> FoldedState` — the pure reduction, and *exactly* the snapshot schema (§9). Its own four-case `FoldedMessageState` (§6.3, rev 5), **not** `MessageState`: `Codable` where the public enum deliberately is not, with `.open(partial:)` for started-and-unterminated generations and no `.interrupted` case at all — a snapshot that could hold `.interrupted` is one that can forge a crash.~~ **M2.1 done** — `Reduce/{QuarantineReason,LoadedEvent,FoldedState,Folder,Fold}.swift`, 112 tests green. `Content`, `Role` and `QuarantinedEvent` gained `Codable`; `FoldedState` also gained a stored **`hasGenesis`**, which is *not* derivable (a nil-title genesis with no messages is indistinguishable from no genesis) and without which resuming a snapshot of a genesis-less log diverges from replay — caught by the P3 split sweep over the hostile fixture.
- ~~`classify(folded, mapping) -> Conversation` — **finalizes and classifies**: `.open ⇒ .interrupted` (I5) plus the mapping; ships the default table (§8) with per-case override.~~ **M2.2 done** — `Reduce/{RecoverabilityMapping,Classify}.swift`, 136 tests green.
- ~~`reduce ≡ classify ∘ fold` convenience.~~ **Done**, and the public entry point — spelled `Conversation(reducing:loadedFrom:mapping:)` since the M2 audit, not a top-level `reduce(_:for:)`. A `Conversation` *is* derived state constructed from a log, which is what an initializer says and what a free verb in the module namespace did not; at a call site the free function also read as though it might be `Sequence.reduce`. The internal pipeline keeps `fold` / `classify` (§6.3 names those seams and snapshots depend on them) — the public surface doesn't inherit the vocabulary.
- ~~The mapping's shape.~~ **A value struct, not a closure or protocol.** The decisive argument is I1: the spec says "same `FoldedState` + same mapping ⇒ same `Conversation`," and for a closure "same mapping" is inexpressible, so that half of I1 could never be asserted. Being `Equatable` turns a spec sentence into a CI assertion, and a table of constants cannot capture a clock or mutable state the way a closure can. Slots map 1:1 onto §8's rows so the table can be diffed against the spec; construction is `.default` plus mutation, with **no public memberwise init**, so adding a future §8 row stays source-compatible. `rateLimited` has no slot — it forwards the error's own duration rather than a constant.
- ~~Whether `classify` walks the tree or the message dictionary.~~ **The dictionary.** A tree walk drops anything unreachable from `rootChildren` (silently losing messages is a worse failure than keeping an orphan) and recurses to a depth that tracks message count in a linear conversation. The I1 exception argument is kept checkable by factoring the per-message transform into `Message.init(_:mapping:)`, so the loop body is a single call with nowhere for an order-dependent step to hide.
- ~~`Folder.collect` recursion.~~ **Now an iterative worklist** (`reconstructRouting`), same traversal order, with a `visited` bound — the fold prevents cycles, but this consumes a *snapshot*, and a decodable-but-corrupt one must terminate rather than spin.
- ~~Decide `FoldedState`'s visibility.~~ **Internal** — consumers only ever hold `Conversation`, which is what makes §6.3's "the folded layer's `Codable` commits to nothing" true by construction rather than by promise. `FoldedState`/`FoldedMessage`/`FoldedMessageState`/`fold` are therefore all internal; `reduce` is the public entry point, and `QuarantineReason`/`QuarantinedEvent` are public because they surface on `Conversation.diagnostics`.
- **`fold` consumes `LoadedEvent`, not `LedgerEvent`** (§6.6 input corollary): rows 1–2 are decode failures that cannot arise inside a fold over decoded events, and a loader that drops an unreadable row turns it into a *gap* diagnostic — a different and false claim. `LoadedEvent.undecodable` also makes the envelope-first decode requirement structural, since identity is `Optional` in exactly the row-1 case.
- Implement all of I1–I7: determinism, totality/quarantine, single-termination, generation-scoped bounds, interruption synthesis (I5 — the entire crash-recovery mechanism), tree/virtual-root integrity, identity.
- The §6.6 quarantine table, row-for-row, **plus** the deliberate non-rules: tolerant-terminal (§6.1 row 3), role-adjacency headroom, gap diagnostics (one per contiguous gap), cascades.
- ~~**Two-stage decode** so quarantine diagnostics can name the event.~~ **Moved to M4** — `LoadedEvent` (above) put the decode boundary in the *loader*, so the reducer never decodes and cannot produce rows 1–2 itself. The requirement is unchanged, just relocated.

**Satisfies:** G1, G2, G4 (interruption logic), G5 (classification).
**Exit:** reducer compiles and passes hand-written unit tests for each invariant; no `fold` path can trap (I2).
**Beta risk:** none — this is pure Swift.

**Coverage against exit criteria.** I2/I6/I7 hold over every *prefix* of a rich and a hostile fixture, asserted as executable predicates rather than one-off expectations — the seed of M3's exhaustive small-scope enumeration, where only the input generator has to widen. I3/I4/I5 have direct unit tests (I5 at the fold layer means "stays `.open`"; synthesis is `classify`'s, tested separately). **I1's first half** is pinned by a golden with literal orderings, deliberately not by repeating a fold in one process: Swift's hasher seed is fixed per process, so only a literal captured in one process and re-checked in later ones catches dictionary-order leakage. **I1's second half** is now directly assertable because the mapping is `Equatable`. P3 is exercised at *every* split point of both fixtures. §8's default table is asserted row for row, plus the lift-order cases (429 and 401/403/407 must be classified before the general 4xx row), and the property that `message` never influences a verdict. **Still M3's:** interior-gap fuzz variants, exact-residue hostile assertions row-for-row, and the version-frozen corpus.

~~**Two §8 items left open**~~ — **both closed in the spec at the M2 audit**, neither by changing code:
- ~~A `providerFailure` status outside 4xx/5xx is not in §8's table.~~ §8 now has the row; the implementation (`providerUnclassified` — `terminal`, the safe default) was already right and is unchanged.
- ~~"Logged loudly" has no home in a pure reducer.~~ §8 now says so explicitly: it is a *normalization-time* obligation (M6), not a classification-time one. Three of the four loud rows are the driver's; the fourth — unmatched provider `code` — is the app's, since only an app that supplied a `providerCodes` table can have an unmatched entry in it. **Accepted rather than solved**: adding provenance to `classify`'s return type would permanently complicate the one signature every consumer calls, to report something the caller can already detect from its own input.

> **M1 audit → spec rev 5 (2026-07-25).** The three M2 decisions this milestone was missing are now settled in the spec, not here: the folded layer's own enum and the `.open` state (§6.3), finalization living inside `classify` (§6.3, I1), and `MessageID` allocate-once closing the §6.6 row-6 hole (I7). Rev 5 is clarifying only — nothing above reverses a rev 4 semantic. See SPEC Appendix C.
>
> **M2 audit → spec rev 5 ratified (2026-07-25).** Two further clarifying items landed and rev 5 is now **ratified**; later amendments open rev 6. (1) The §8 row and the "logged loudly" acceptance above. (2) **Row ordering is recorded as a non-rule** (§6.6): reduction requires ascending `sequence` and neither verifies nor repairs violations — only `deltaAppended` and `toolInvocationRecorded` are non-idempotent under replay, everything else quarantines on a once-only rule or is last-write-wins. Pinned by `FolderOrderingTests`, which is the fixture M3's generators and any v0.3 import tooling inherit. Code changes from this audit were confined to the API surface (`Conversation(reducing:loadedFrom:mapping:)`), the M4 seam (`PersistenceStore.events` → `[LoadedEvent]`), and doc corrections — **no reducer semantics changed**.

### ~~M3 — Test corpus + `ScriptedLanguageModel` (the differentiation)~~ ✅ **done 2026-07-26**
Spec §10 is explicit that "how do you test an FM app?" is the marketing wedge. This milestone is co-equal with M2 and can interleave with it.

**196 tests green** — 175 in `LedgerKit`, 21 in the test-double package, both packages warning-free, whole suite ≈0.2 s. Build order and detail: [M3-PLAN.md](./M3-PLAN.md), which carries the decision log (D1–D12) and the per-phase audit notes.

> **Naming note for readers of this section:** the test-double package shipped here as `LedgerKitTestSupport` and was renamed **`Understudy`** at M4 Phase 0 (M4-PLAN D14). M3's records below keep the old name as a matter of record; the package on disk is `Understudy/`.

- ~~`ScriptedLanguageModel` in `LedgerKitTestSupport` (§10.1) — conforms to Apple's `LanguageModel` (model+executor). **The conformance surface is OQ3** — stub it behind an internal protocol now, bind to the real thing at M6.~~ **Conforms to the real protocols now** (D11): the SDK is installed, so the surface was read rather than guessed. Engine and script vocabulary are platform-agnostic (26+); only the conformance is `@available(macOS 27)`. Public vocabulary: `Script` / `Script.Step` (`.emit` `.wait` `.waitFor` `.reportUsage` `.reportMetadata` `.fail`), `Cue`, `ScriptExhaustion`. *(`.waitFor(_:)` was renamed `.wait(until:)` at the M4 boundary audit — prepositions belong in argument labels; this record keeps the name it shipped with.)*
- ~~**Golden logs** (§10.2)~~ — 7 golden + 3 hostile fixtures in one `Corpus` registry every sweep iterates. The audit's sharpest finding: *both* pre-existing fixtures were hostile, so no sweep had ever seen a healthy log.
- ~~**Hostile fixtures** (§10.2): the §6.6 table row-for-row…~~ **Reshaped (D8).** Per-row fixtures would have duplicated unit tests that already assert exact reasons; the corpus instead holds logs worth *sweeping*, and the five genuine gaps became rule-named tests. Three of those gaps were *relationships* between rules — one rule at three sites, row 9 vs row 10, what must not quarantine — which no per-row fixture could have expressed.
- ~~**Crash-point fuzzing** (§10.3)~~ — exhaustive, not randomised: 520 interior-gap mutations (393 producing multi-row holes) and 3,289 compound truncation×gap iterations, plus `truncationIsMonotone`, which states the crash-recovery guarantee directly rather than by proxy.
- ~~**Version-frozen corpus** scaffolding (§10.2)~~ — three directories: `dev/` (regenerable), `wire/` (hand-authored bytes this version cannot write), `frozen/` (empty until 0.1.0). Freeze procedure in `Corpus/README.md`.

**Satisfies:** G6; hardens G1/G2/G4.
**Exit:** ✅ I1–I7 provable via green suites; crash-fuzz green; hostile fixtures assert exact residue **in both dimensions** (reason *and* sequence, via `ExpectedDiagnostic` — a reason-only assertion passes even when the reducer blames the wrong row). DoD-3 down payment made.

> **M3 audit → SPEC rev 6 ratified (2026-07-26).** Three amendments, all sourced from the installed SDK rather than from inference: §8's taxonomy reconciled against the real `LanguageModelError` (`contextWindowExceeded` → `contextSizeExceeded`, `refusal` added, the four `unsupported*` built-ins grouped rather than silently absorbed by `unrecognized`), §7.3's provider-writes-deltas / consumer-reads-snapshots distinction, and §10.1 recording that `LedgerKitTestSupport` is a provisional name. ADR-001 gains a **reserved-tag table** — the mechanism that makes "tags are never reused" auditable rather than aspirational. See SPEC Appendix D.
>
> **Deviations from the plan, all recorded with reasoning in [M3-PLAN.md](./M3-PLAN.md):** D8 (corpus holds logs worth sweeping; unit tests name rules — no per-row duplication), D10 (frozen dumps render `FoldedState`, never `Conversation`, so legitimate §8 mapping changes cannot break the frozen corpus), D11 (conform now, availability-gated — supersedes D4), D12 (`Script.Step` is a struct with static factories, not an enum).
>
> **Practice that paid for itself repeatedly: mutation testing.** Every suite whose failure mode was subtle got a deliberate breakage injected and reverted. It found a real hole Phase 4 would otherwise have shipped — deleting the script player's between-step cancellation check left the *entire* suite green, because every step that suspends already throws on cancellation by itself, so the tests were only ever proving that `Cue` works. Worth carrying into M4–M7.

**Handoffs to M4** (also in the plan): the on-disk corpus reserves a `raw` row form for undecodable rows, which is why `rich` and `hostile` have no file yet — those are *loader* outcomes, and synthesising them test-side would freeze fixtures against a reimplementation of the decode boundary. M4's loader tests should consume the same corpus files, and the store must stamp timestamps **born** canonical (`timestampsAreCanonical` already fails if it slips).
**Beta risk:** ~~OQ3 (conformance surface) — isolated behind the internal protocol.~~ **None — OQ3 closed.**

> **The premise this milestone was planned under was wrong, in our favour.** The build machine has **Xcode 27 with the macOS 27 SDK**, so `FoundationModels`' iOS/macOS 27 API is not a beta unknown to be stubbed around — it is 3,583 lines of readable `.swiftinterface`. **OQ3 and OQ5 are closed by reading it** (SPEC rev 6), and `ScriptedLanguageModel` conforms to the real protocols behind `@available(macOS 27)` rather than to an internal imitation. The engine and script vocabulary stay platform-agnostic, so "M1–M5 verify on any Mac" survives intact.
>
> **Consequence for M6, worth acting on early:** several §14 open questions are answerable the same way, by reading rather than by spiking. OQ1 (transcript seeding), OQ4 (stream element type — *answered in passing*: `ResponseStream.Snapshot`), OQ8 and OQ9 all name types that exist in the SDK today. The per-beta verification evening is still real, but it starts from a much smaller list than this roadmap assumed.

**Spec work generated by this milestone (rev 6, ratifies at the M3 boundary):** §8's taxonomy reconciled against the real `LanguageModelError` — `contextWindowExceeded` renamed to `contextSizeExceeded` (a wire change, free pre-1.0, with the old tag reserved in ADR-001), `refusal` added, and the four `unsupported*` built-ins grouped into `unsupported(UnsupportedFeature)` instead of falling through to `unrecognized`; §7.3 gains the provider-writes-deltas / consumer-reads-snapshots distinction; §10.1 records that `LedgerKitTestSupport` is a provisional name. See SPEC Appendix D.

### ~~M4 — Persistence: SQLite store, snapshots, index~~ ✅ **done 2026-07-26**
Three tables, append-only truth (§9). **266 tests green** — 245 in `LedgerKit`, 21 in `Understudy`, both packages warning-free, whole suite ≈0.6 s (the growth is almost entirely the 10k-event cold-open fixture *appending*; the resume it measures is ~28 ms). Build order, decision log (D13–D20) and per-phase audit notes: **[M4-PLAN.md](./M4-PLAN.md)**.

> **Scope grew at the M3 boundary audit (2026-07-26), deliberately.** M4 *started* with a contract-hygiene phase applying the audit's API findings — **✅ done 2026-07-26, 200 tests green**: the derived-state memberwise inits went internal (so reducing a log is the only public way to obtain a `Conversation`), `Content` → `MessageContent`, labels on `MessageState.failed`, a non-contractual `CustomStringConvertible` on `GenerationError`, `PersistenceConfiguration` and `ScriptExhaustion` as structs with factories, and `LedgerKitTestSupport` renamed **`Understudy`** (D14) — because these are breaking changes that are free before M4/M5 give the surface callers and migrations after. **SPEC rev 7 is ratified** (see the boundary note at the end of this section).

> **Phase 1 done 2026-07-26 — GRDB is wired, 223 tests green.** Three `STRICT` tables, the six verbs, the two-stage envelope-first loader, `WireJSON` as the one production encoder, and `LedgerSchema`'s two deliberately-separate version numbers. **ADR-003 is Accepted** (ratified by wiring); **ADR-001 D-1 (canonical encoder) and D-2 (schema version is column-only) are closed**. Decisions taken: `schema_version` column-only, `DatabasePool`/`DatabaseQueue` per configuration, and `events.payload` as TEXT so a log is readable through `sqlite3` (M4-PLAN D19).

- ~~`events` (keyed `(conversation_id, sequence)` UNIQUE; sequence lives *only* in the key, blob omits it — §9/§6.1).~~ ✅ **`STRICT`**, and `payload` is **TEXT** so a log prints readably through `sqlite3` (D19); `schema_version` is column-only (D16).
> **Phase 2 done 2026-07-26 — corpus integration, 226 tests green.** The `raw` row form is implemented *through the production loader*, so M3's two handoffs close: damaged corpus rows are now **derived from bytes** rather than synthesized, and `rich`/`hostile` are on disk because of it. `wire/undecodableRows` adds hand-authored rows 1 and 2. A new sweep writes every replayable fixture through the real store and folds it back, joining two layers that were previously right about the same logs independently. One finding pinned for rev 7: §6.6 rows 1–2 have no case for "known kind, malformed body".

- **Two-stage decode in the loader**, emitting `LoadedEvent` (moved here from M2). Decode the envelope first, then the payload: M1's `Record.init(from:)` decodes the payload with a plain `try`, so an unknown discriminator discards the whole record, envelope included, and every §6.6 row-2 diagnostic degrades to sequence-only. Also: an unreadable row must be **emitted, not dropped** — dropping it turns a row-1/2 condition into a *gap* diagnostic, which is a different and false claim (§6.6 input corollary). *(M2 audit: `PersistenceStore.events` now returns `[LoadedEvent]`. As first typed it returned `[LedgerEvent]`, which can represent neither an emitted-undecodable row nor a throw that doesn't sink the whole conversation — so it made this task unimplementable above the seam and forced decode below it, against ADR-003 rule 2. `append` still takes typed records: encoding is total, decoding is not.)*
> **Phase 3 done 2026-07-26 — snapshots + cold open, 239 tests green.** `Store/Snapshots.swift` adds checkpoint coding, a four-condition discard policy (either version, undecodable payload, foreign payload, impossible sequence — one branch, never fatal), and the resume path as a *composition* above the seam rather than a seventh verb. P3 now runs twice: through the **codec** over every fixture (the only sweep that reaches `diagnostics`, which §9 requires snapshots to persist) and through the **store** over every replayable one. **The cold-open exit criterion is met and measured: 10,004 events → 3 rows replayed, ~28 ms**, observed on the resume path itself via a counting `PersistenceStore` wrapper.

> **Phase 4 done 2026-07-26 — properties, the registry, and the one wire change; 266 tests green.** **P1** runs at every flush boundary of every replayable fixture, at the fold *and* classified levels — and implementing it corrected the spec: P1 is a **store** property, not a pure one, because its real question is whether the values `append` *returned* are interchangeable with the bytes a re-read decodes, which in memory is unaskable. **P2's harness** ships before its overlay, parameterized over it, with the predicate itself tested against deliberately wrong projections. **ADR-001 D-3 closes** as a checked-in `Registry/tags.json` compared against what the codecs encode in both directions — with deletion caught by the *compiler*, because the test reads the same exhaustive inventories the round-trips do. **D17** widened `contextSizeExceeded` to carry Apple's two numbers; `dev/` came back byte-identical, which is the additive claim proven rather than asserted. Six mutations injected, six caught, all reverted.

> **Phase 5 done 2026-07-26 — SPEC rev 7 ratified.** Drafted to a scratch file and reviewed item by item before `SPEC.md` was touched; the draft was then retired rather than left to drift. **A misreading in the M3 audit's fact table was caught in the process** — `Transcript.Entry` did *not* gain a seventh case (`Transcript.Segment` is what grew), so N11's six-kind count was right all along and the amendment landed one level down. M4-PLAN §2 now carries the correction plus the confirmed citation list, so M6 need not repeat the check.

- ~~`snapshots` — periodic `FoldedState` checkpoints carrying reducer + schema version; **must persist accumulated `diagnostics`** (§9, or P3 fails); discard-on-mismatch, no migrations.~~ ✅ Four discard conditions, one branch, never fatal. Diagnostics are persisted *and* the codec sweep counts the checkpoints that carried some, so the requirement cannot pass vacuously.
- ~~`conversations` — index projection (id, created_at, title, last_event_at), maintained on **non-delta** appends only (§9 — no ~4 Hz churn).~~ ✅ Derived from an exhaustive `Payload.updatesIndex`, so a future payload kind cannot be added without deciding its side of the line.
- ~~Atomicity: multi-event operations commit in one transaction (§9).~~ ✅ One transaction per `append`, sequence assigned **inside** the write, whole-batch rejection *before* it opens.
- ~~**P1–P3** property tests (§10.6): fold/tail equivalence, overlay correctness scaffolding, and snapshot equivalence `resume(snapshot, suffix) == fold(fullLog)` *including diagnostics*.~~ ✅ All three, **exhaustive rather than randomized** — fixtures are ≤22 rows, so every split of every fixture runs in milliseconds and buys no seed, no flake, and failures that reproduce by re-running (rev 7 amends §10.6 to say so).
- ⚠️ **Stamp timestamps at wire precision.** The wire form is millisecond ISO 8601 (ADR-001), but `Date` carries finer precision, so a raw `Date()` does **not** survive a round-trip equality-intact. P1 and P3 compare an in-memory tail against a re-decoded log, so an unrounded stamp makes them fail on timestamp jitter — or, worse, pressures the assertions into fudging equality. Canonicalize at *birth* (truncate when the store stamps), not at encode: canonicalize-at-encode gives every event two identities depending on whether it has been to disk, which is the exact bug class P3 exists to catch. ✅ **Done, and asserted rather than repaired:** `append` *debug-asserts* its records arrive canonical instead of canonicalizing them, because repairing at write time would give every event two identities depending on whether it had been to disk.

**Satisfies:** G1 (atomic persistence), G9 (index), snapshot fast-path.
**Exit:** ✅ cold-open of a 10k-event conversation replays ≤ one generation's suffix (**10,004 → 3 rows**, asserted as a row count, which is deterministic where wall time is not); P1 & P3 green corpus-wide against the real store; the index is one table read.
**Beta risk:** none (GRDB/sqlite, no FM) — as predicted, this milestone never touched a beta API.

> **M4 audit → SPEC rev 7 ratified (2026-07-26).** Its character: rev 6 was the first revision written against the installed SDK and closed two open questions by reading a file; **rev 7 closed seven more the same way.** The finding worth carrying forward is uncomfortable and cheap to act on — *nine open questions were carried for three milestones on the assumption they were empirical, and seven were answerable by opening `FoundationModels.swiftinterface`.* **Read the interface first; a spike evening is for what the interface cannot answer.** One change was wire-affecting (`contextSizeExceeded`'s payload, additive by construction); §6.6 row 2 had its *description* widened with no change in behaviour; and rev 7 also recorded what implementing M4 taught — the TEXT payload, the four-way snapshot discard, GRDB as the decided backend, P1-as-store-property, exhaustive sweeps, and the mechanically-enforced registry. See SPEC Appendix E.
>
> **Deviations from the plan, recorded with reasoning in [M4-PLAN.md](./M4-PLAN.md):** D16 (schema version column-only), D19 (`events.payload` TEXT, decided while writing the DDL), D20 (D-3 closes as a manifest test *coupled to the exhaustive inventories*, because a manifest alone cannot see a deletion). The loader and its unit tests were also pulled forward from Phase 2 into Phase 1 — `load` is a pure function over bytes, so testing it through a database would have added I/O and a GRDB dependency in the test target to verify something with no storage in it.
>
> **Handoffs to M5** (five, in [M4-PLAN.md](./M4-PLAN.md) §7): the store actor is the **stamping site** and must mint timestamps canonical at birth (ADR-001 R-5 — both `append`'s debug assertion and the corpus's `timestampsAreCanonical` fail if it slips); snapshot **refresh policy** (§9's after-each-terminal cadence with a 500-event floor) is actor behaviour, since nothing at M4 *triggers* a refresh; **`LedgerError` is designed at M5**, against the real verbs, and M4 deliberately pre-committed no public error surface; `append` **returns the assembled tail** so the actor folds forward instead of re-reading — P1 is the property that makes that legal, and it is green before M5 starts; and in-flight registration / the live set is M5's, with `overlay_live` and P2's completion at M7.

### M5 — `ConversationStore` actor + turn verbs
The concurrency boundary and the public write API (§6.5, §11). Still no FM — verbs take a driver but M5 can test against a no-op/scripted driver.

- Actor owning all writes; single-flight per conversation (`generationInFlight`), cross-conversation free.
- **Start atomicity** (§6.5): single-flight check + appends + in-flight registration in one critical section; a losing `send` racer records *nothing*.
- Verbs: `createConversation`, `setInstructions`, `setTitle`, `send`, `respond`, `regenerate` (exact sugar for `respond(to: parent)`), `edit`, `switchBranch`, `cancelGeneration`, `deleteConversation` (cancels-first, §9).
- Target eligibility (§6.5): respond→user, regenerate→assistant, edit→user.
- The two-channel contract (§11): `try` guards *did it start*; return value answers *how it ended*.

**Satisfies:** G2 (branching verbs), lifecycle for G9.
**Exit:** the §11 API sketch compiles and runs against a scripted driver; single-flight & atomicity have chaos tests (cancellation chaos, §10.4).
**Beta risk:** none directly; consumes the driver interface defined at M6 (define the protocol here, implement there).

### M6 — `GenerationDriver`: the session seam (⚠️ ALL beta risk)
The one OS-coupled module (§7). Expect one verification evening per beta — but **a much shorter one than this roadmap was planned around**: OQ1–9 are all closed as of rev 7, every one by reading the SDK, and what is left here is four *behavioural* residues (table under Beta-verification, below). The API shapes this milestone consumes are known; what is unknown is how they act.

- Takes `any LanguageModel`; per-conversation session cache (§7.8 cardinality).
- **Rehydration** (§7.1) — materialize active path + instructions into a seeded transcript via `LanguageModelSession(model:tools:transcript:)` (**OQ1 closed**). Text-fidelity only (N11 fidelity classes).
- **Outcome boundary** (§7.2) — `generationStarted` appended *before* the provider request; every post-append failure is an `Outcome`, never a throw (this is what makes §8's reauth row reachable). `isResponding` defensive gate — **kept even though OQ6 closed**, because the iOS 26 error family is deprecated rather than removed, and because §6.5's parallel-generation relaxation is exactly when store single-flight stops covering for it. *Residue: thrown or trapped.*
- **Streaming reduction** (§7.3) — diff cumulative snapshots → `deltaAppended` suffix; fail the generation on a non-prefix snapshot. **Rev 7 promoted this from a can't-happen assertion to a real path:** `replaceTextSegment` exists, so prefix-stability is provider behaviour, not an API guarantee. Prefer **segment-aware diffing** via `Snapshot.transcriptEntries`, falling back to flat-string prefix-diffing only where entries are unavailable (**OQ4 closed**; *residue: do real providers revise?*).
- **Delta batching** (§7.4) — only `deltaAppended` coalesces (~250ms/N chars); all else appends synchronously.
- **Cancellation** (§7.5), **tool records** (§7.6 — record, don't orchestrate; `.metadataOnly` default; **OQ2 closed**, so live tool UI is now *possible* and still deliberately a session concern), **usage** (§7.7 → `StopInfo`, mapping table in the spec; *residue: is input's total inclusive of cached?*), **provider swap + model identity** (§7.8 — **OQ8 closed**: the requested descriptor is app-supplied, and `resolvedModelID` should be expected nil on-device rather than treated as a gap).
- **Error normalization** (§8): thrown error → `GenerationError`, one file per provider family; fixture-tested (§10.5); the lift rules — 429 / `Retry-After` in both RFC forms **and Apple's `RateLimited.resetDate`**, 408/timeout → transport. **Two error families, not one:** `LanguageModelError` and the deprecated-but-present iOS 26 `LanguageModelSession.GenerationError`. And D17's payload means `contextSizeExceeded` now carries `contextSize`/`tokenCount` — normalization should populate them where Apple's error provides them.

**Satisfies:** G3, completes G4/G5, G8 (provider swap).
**Exit:** on-device + Claude-package mappings pass §10.5 fixtures; a real stream captured & reduced end-to-end; the four behavioural residues answered and written back into the spec where they change anything.
**Beta risk:** **high and expected.** This milestone re-opens each beta. Cut-line fallbacks live here (see below).

### M7 — Observable projection + `overlay_live`
The `@MainActor @Observable` read side (§6.2, §7.4, §11).

- `projection = overlay_live(reduce(persistedLog ++ unflushedTail, mapping))`, where `overlay_live` maps `.interrupted → .streaming` for in-flight `GenerationID`s only, identity otherwise.
- **P2** (overlay correctness, §10.6): live set ⊆ open generations; crash recovery is the degenerate empty-live-set case (overlay disappears → `.interrupted` shows through). **The harness already exists** — M4 Phase 4 shipped `ProjectionChecks.swift` with the predicate parameterized over the overlay (`LiveOverlay`), swept over every truncation of every fixture with an empty live set, and with the predicate itself tested against deliberately wrong projections. **M7 supplies the real `overlay_live` as an argument and should need to change no assertion**; if it does, that is a signal worth stopping on. `referenceOverlay` in the test target is a *control*, not a draft implementation — do not promote it.
- `conversationList` on the projection (not the store actor, which exposes no synchronous reads).
- Deltas hop to main actor at *display* cadence (~a frame), independent of disk flush.

**Satisfies:** G7.
**Exit:** P2 green; streaming renders smoothly in a preview driven by `ScriptedLanguageModel`; recovery = overlay vanishing, no recovery pass.
**Beta risk:** none (pure projection over reducer output).

### M8 — `Projection` demo app (the hero)
The [Projection](../Projection) Xcode app (built from `LedgerKit.xcworkspace`, scheme `Projection`; earlier drafts of this roadmap called it "Scroll"). DoD-1 and DoD-2.

> Not to be confused with [LedgerKit/Sources/LedgerKit/Projection/](../LedgerKit/Sources/LedgerKit/Projection/) — the library's internal observable-projection layer, which is M7.

- Chat UI driving the exhaustive `switch message.state` (§11) — the code-aesthetics showpiece.
- **Kill-and-relaunch:** kill mid-stream → relaunch → `.interrupted` with partial text; Regenerate works; the interrupted partial survives as its own branch, reachable via the branch switcher (**DoD-1**, the README hero GIF).
- **Provider swap:** `SystemLanguageModel` → Claude package with only the driver-init line changed (**DoD-2**).

**Satisfies:** G8, DoD-1, DoD-2.
**Exit:** the kill/relaunch GIF is recordable; provider swap compiles & runs with a one-line change.
**Beta risk:** medium — depends on M6 being beta-stable and on real model availability.

### M9 — README, ADR-001, tag `0.1.0`
DoD-3/4/5.

- README: 60-second quickstart, the recoverability table, the exhaustive-switch example, and the **"why not just persist `session.transcript`?"** section (§2 incumbent argument, the five-way failure — **DoD-4**).
- **ADR-001** ratified (§9, §6.1): tagged-JSON encoding, discriminator registry (tags never reused, removed tags reserved), unknown-discriminator→quarantine + tolerant-terminal exception, gap-diagnostic rule, version-frozen corpus, upcasters named as the evolution idiom. Its open items D-1–D-3 close here. *(ADR-002 was accepted at M1 and ADR-003 ratifies at M4, so DoD-5's "ADR-001 committed" reads as the ADR set being settled.)*
- Full CI green: crash-fuzz (suffix + interior-gap), cancellation chaos, hostile-fixture quarantine (§6.6 row-for-row + non-rules + cascade), **P1–P3** (**DoD-3**).
- Tag `0.1.0`; pre-1.0 SemVer caveats (**DoD-5**).

**Satisfies:** DoD-3, DoD-4, DoD-5.
**Exit:** all five DoD items checked; `0.1.0` tagged.
**Beta risk:** low.

---

## Beta-verification track (runs parallel from M6 on)

GA is ~Sept 2026. Treat this as a recurring per-beta checklist, not a one-time gate — but the list is now much shorter than this roadmap was planned around.

> **All nine OQs are closed as of SPEC rev 7 (2026-07-26, M4 boundary) — every one of them by *reading* the installed SDK rather than by running it** (Beta 4 swiftinterface; the confirmed citation list is [M4-PLAN.md](./M4-PLAN.md) §2). OQ3 and OQ5 closed at M3 in rev 6; OQ1/2/4/6/7/8/9 closed at M4 in rev 7. **The lesson is the one worth carrying into M6:** these were carried for three milestones as "one spike evening each, likely recurring," and seven of them were a file read away. Read the interface first; spend the evening on what the interface cannot answer.
>
> **What is genuinely empirical, and therefore actually M6's** (also listed at the head of SPEC §14):
>
> | Residue | Why only running it answers this |
> |---|---|
> | Is `LanguageModelSession.Error.concurrentRequests` **thrown** or **trapped**? (OQ6) | A precondition failure is a different design problem from a catchable error, and the interface cannot say which it is |
> | Do real providers ever emit **`replaceTextSegment`** on plain text? (OQ4) | The API *permits* segment revision, so the prefix property is provider behaviour; the driver's fail-loud path fires only if someone actually does it |
> | Is `Usage.Input.totalTokenCount` **inclusive of** `cachedTokenCount`? (§7.7) | Undocumented, and it decides whether an app may sum the two |
> | The real on-device **context budget** (~4k shared tokens, reported) | N3's remaining ⚠️ — it sets how soon a long conversation becomes unregenerable after process death |
>
> Re-verify the closed ones per beta. A **new built-in error case**, or a change to `LanguageModel`'s two protocol requirements, is the kind of change that reopens one.

| OQ | What to pin | Blocks |
|----|-------------|--------|
| ~~OQ1~~ | ~~Transcript-seeding initializer shape~~ | **Closed at M4 (rev 7)**: `LanguageModelSession(model: some LanguageModel, tools:, transcript:)`, generic over the model, so rehydration is provider-agnostic. No residue |
| ~~OQ2~~ | ~~Tool-activity observation surface~~ | **Closed at M4 (rev 7)**: `Snapshot.transcriptEntries` mid-stream; `ToolCalls`/`ToolOutput` publicly constructible, so v0.2 transcript fidelity is a scoping decision, not an API bet. v0.1's stance unchanged |
| ~~OQ3~~ | ~~`LanguageModel` conformance surface~~ | **Closed at M3 (rev 6)** by reading the SDK interface; `ScriptedLanguageModel` conforms to the real protocols |
| ~~OQ4~~ | ~~Cumulative-snapshot stream element type~~ | **Closed at M4 (rev 7)**: `ResponseStream<Content>.Snapshot { content, rawContent, transcriptEntries, usage }`. **It also withdrew a guarantee** — `replaceTextSegment` makes prefix-stability provider behaviour, not API. §7.3 amended; residue above |
| ~~OQ5~~ | ~~Built-in `LanguageModelError` case names~~ | **Closed at M3 (rev 6)**; §8 reconciled and its coverage stated as a table |
| ~~OQ6~~ | ~~Session single-flight error surface~~ | **Closed at M4 (rev 7)**: typed `.concurrentRequests` (27+), split out of the iOS 26 enum that also held `rateLimited` — which is *why* the 26 evidence read that way. The 26 enum is deprecated, not gone, so §8 normalizes both families. Residue above |
| ~~OQ7~~ | ~~Context/KV-cache APIs stop at session edge~~ | **Closed at M4 (rev 7) — the sherlock check passes.** All session-scoped, none persistent; and `Transcript` being officially mutable is an argument *for* durable truth outside it. No residue |
| ~~OQ8~~ | ~~Requested-descriptor derivability~~ | **Closed at M4 (rev 7)**: not derivable — the protocol is `capabilities` + an opaque configuration, with no model-identity key anywhere. App-supplied at driver init; `resolvedModelID` is per-provider convention, **nil expected on-device** |
| ~~OQ9~~ | ~~Reasoning / custom segment exposure~~ | **Closed at M4 (rev 7)**: observable *and* constructible, so v0.1's silence is an owned choice (N11), not an incapacity. `Transcript.Segment` also gained `attachment`/`custom` — entries did **not** change |

---

## Cut line (if slipping — spec §12, in order)

Cut from the *top* first; never cross the "never cut" line.

1. Branch-switcher UX in the demo (keep the events, hide the UI).
2. GRDB polish → naive SQLite.
3. Tool-invocation recording → v0.2.
4. Provider-mapping breadth → ship on-device + Claude-package only; Chat-Completions → v0.2.

**Never cut:** I1–I7 **and** P1–P3 tests, interruption recovery, `ScriptedLanguageModel`.

---

## Goal & DoD traceability

| Spec goal | Milestone(s) |
|-----------|--------------|
| G1 append-only log, atomic persistence, deterministic reduction | M1, M2, M4 |
| G2 message tree, edit-as-branch, regenerate-as-sibling | M1, M2, M5 |
| G3 generation driver over `LanguageModelSession` | M6 |
| G4 interruption recovery → `.interrupted` | M2 (logic), M6 (driver), M8 (demo) |
| G5 error taxonomy + recoverability | M1, M2, M6 |
| G6 `ScriptedLanguageModel` + golden logs + property tests | M3 |
| G7 `@Observable` projection | M7 |
| G8 demo app + one-line provider swap | M6, M8 |
| G9 conversation index | M4, M5 |

| DoD | Milestone |
|-----|-----------|
| 1 kill-mid-stream GIF, partial-as-branch | M8 |
| 2 one-line provider swap | M6, M8 |
| 3 crash-fuzz + chaos + hostile + P1–P3 green | M3, M4, M7, M9 |
| 4 README with "why not the transcript blob?" | M9 |
| 5 tagged `0.1.0`, ADR-001 committed | M9 |

---

## Critical path

```
M0 → M1 → M2 ─┬─ M3 (interleaves with M2)
              └─ M4 → M5 → M6 → M7 → M8 → M9
```

M3 runs *alongside* M2 (the corpus is how you know the reducer is right). M6 is the schedule risk — it's the only milestone the betas can re-open, which is exactly why everything cheap and certain sits in front of it.
