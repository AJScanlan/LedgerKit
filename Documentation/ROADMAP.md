# LedgerKit v0.1 — Build Roadmap

**Companion to:** [ledgerkit-v0_1-spec-rev4.md](./ledgerkit-v0_1-spec-rev4.md)
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
GenerationDriver (§7)  ◄──── ALL beta risk (⚠️ / OQ1–9) lives here, and only here
        │
Observable projection + overlay_live (§6.2, §7.4, §11)
        │
Scroll demo app (§13 DoD-1/2)
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
The current [ChatEvent.swift](../LedgerKit/Sources/LedgerKit/Data/Models/ChatEvent.swift) and [Message.swift](../LedgerKit/Sources/LedgerKit/Data/Models/Message.swift) are *pre-spec* stubs (linear `tokenAppended` events, a flat 3-case status with no branching/interruption/recoverability). They contradict §6 and must be replaced, not extended.

~~- Delete the stub types; establish the source tree layout (`Core/`, `Reduce/`, `Store/`, `Session/`, `Projection/`).~~

~~- Split the package into two products: `LedgerKit` and `LedgerKitTestSupport` (the Scripted model ships separately — spec §10.1, "the gateway drug").~~

**Exit:** empty package builds under Swift 6 strict concurrency; two products resolve; stubs gone.
**Beta risk:** none.

### M1 — Core types (pure, wire format)
The event log and derived-state vocabulary. This is API surface *forever* (§6.1) — get the shapes right, names are bikesheddable.

~~- `EventID` (UUIDv7 generator — ours, Foundation only mints v4, §6.1), `ConversationID`, `MessageID`, `GenerationID`, `Int64` sequence.~~

~~- `LedgerEvent` + the ten-kind `Payload` enum, `Outcome`, `ToolRecord`, `StopInfo`, `ModelDescriptor` (§6.1).~~

~~- Derived state: `Conversation`, `Message`, `MessageState` (5 cases), `Content` (struct, not `String` — §6.2 additive-headroom), `QuarantinedEvent`.~~ *(plus `MessageTree`'s read API: optional subscript, `children(of:)`, exclusive `siblings(of:)` with virtual-root support, `Conversation.activeMessages`)*

~~- `GenerationError`, `Recoverability`, `RequiredAction` (§8) — note `Recoverability` is **not** `Codable` (derived, never persisted).~~
~~- Tagged-JSON `Codable` conformances with a discriminator registry (ADR-001 territory — draft the ADR here even if it's ratified at M9).~~ *(conformances landed; ADR-001 drafted with R-1–R-4 recorded, D-1–D-3 open for M9)*
- Decide the persistence dependency (GRDB) behind a small protocol — but don't wire it yet (§9: "decide at implementation, don't bikeshed now").

**Satisfies:** foundation for G1–G9.
**Exit:** every type round-trips through `Codable`; `MessageState`/`Recoverability` deliberately have no persistence path; a `swift build` is clean.
**Beta risk:** low — `StopInfo`/`ModelDescriptor`/`GenerationError` field names are ⚠️ (OQ5, OQ8, §7.7) but the *shapes* are stable; pin field names at M6.

### M2 — The reducer: `fold → classify` (the heart)
Pure functions over `Sendable` values, `nonisolated`, no clocks, no I/O (§6.3, §11 isolation sketch).

- `fold(log) -> FoldedState` — the pure reduction. `FoldedState` = `Conversation` minus `Recoverability`, and is *exactly* the snapshot schema (§9), so name it deliberately.
- `classify(folded, mapping) -> Conversation` — applies the `(GenerationError) -> Recoverability` mapping; ships the default table (§8) with per-case override.
- `reduce ≡ classify ∘ fold` convenience.
- Implement all of I1–I7: determinism, totality/quarantine, single-termination, generation-scoped bounds, interruption synthesis (I5 — the entire crash-recovery mechanism), tree/virtual-root integrity, identity.
- The §6.6 quarantine table, row-for-row, **plus** the deliberate non-rules: tolerant-terminal (§6.1 row 3), role-adjacency headroom, gap diagnostics (one per contiguous gap), cascades.

**Satisfies:** G1, G2, G4 (interruption logic), G5 (classification).
**Exit:** reducer compiles and passes hand-written unit tests for each invariant; no `fold` path can trap (I2).
**Beta risk:** none — this is pure Swift.

### M3 — Test corpus + `ScriptedLanguageModel` (the differentiation)
Spec §10 is explicit that "how do you test an FM app?" is the marketing wedge. This milestone is co-equal with M2 and can interleave with it.

- `ScriptedLanguageModel` in `LedgerKitTestSupport` (§10.1) — conforms to Apple's `LanguageModel` (model+executor). **The conformance surface is OQ3** — stub it behind an internal protocol now, bind to the real thing at M6. The *scripting* logic (emit snapshot / wait / throw / complete) is beta-independent.
- **Golden logs** (§10.2): fixture log → expected reduced state, snapshot-tested; doubles as living docs.
- **Hostile fixtures** (§10.2): the §6.6 table row-for-row, each asserting exact `diagnostics` residue; the tolerant-terminal *non*-quarantine; role-adjacency non-rules; the cascade fixture; mid-log gap fixture; root-message-edit-as-sibling.
- **Crash-point fuzzing** (§10.3): truncate every fixture at every prefix + interior-gap variant; assert valid state, correct `.interrupted` (I5), no traps (I2). Spec calls this "the single highest-value suite."
- **Version-frozen corpus** scaffolding (§10.2) — freeze released-version fixtures in CI forever.

**Satisfies:** G6; hardens G1/G2/G4.
**Exit:** I1–I7 provable via green suites; crash-fuzz green; hostile fixtures assert exact residue. This is a DoD-3 down payment.
**Beta risk:** OQ3 (conformance surface) — isolated behind the internal protocol.

### M4 — Persistence: SQLite store, snapshots, index
Three tables, append-only truth (§9).

- `events` (keyed `(conversation_id, sequence)` UNIQUE; sequence lives *only* in the key, blob omits it — §9/§6.1).
- `snapshots` — periodic `FoldedState` checkpoints carrying reducer + schema version; **must persist accumulated `diagnostics`** (§9, or P3 fails); discard-on-mismatch, no migrations.
- `conversations` — index projection (id, created_at, title, last_event_at), maintained on **non-delta** appends only (§9 — no ~4 Hz churn).
- Atomicity: multi-event operations commit in one transaction (§9).
- **P1–P3** property tests (§10.6): fold/tail equivalence, overlay correctness scaffolding, and snapshot equivalence `resume(snapshot, suffix) == fold(fullLog)` *including diagnostics*.

**Satisfies:** G1 (atomic persistence), G9 (index), snapshot fast-path.
**Exit:** cold-open of a 10k-event conversation replays ≤ one generation's suffix; P1 & P3 green; index is a table read, not N reductions.
**Beta risk:** none (GRDB/sqlite, no FM).

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
The one OS-coupled module (§7). Everything ⚠️/OQ1–9 concentrates here. Expect one verification evening per beta.

- Takes `any LanguageModel`; per-conversation session cache (§7.8 cardinality).
- **Rehydration** (§7.1) — materialize active path + instructions into a seeded transcript (**OQ1**: seeding initializer shape). Text-fidelity only (N11 fidelity classes).
- **Outcome boundary** (§7.2) — `generationStarted` appended *before* the provider request; every post-append failure is an `Outcome`, never a throw (this is what makes §8's reauth row reachable). `isResponding` defensive gate (**OQ6**).
- **Streaming reduction** (§7.3) — diff cumulative snapshots → `deltaAppended` suffix; prefix-property assertion; fail-generation on violation (**OQ4**).
- **Delta batching** (§7.4) — only `deltaAppended` coalesces (~250ms/N chars); all else appends synchronously.
- **Cancellation** (§7.5), **tool records** (§7.6, **OQ2** — record, don't orchestrate; `.metadataOnly` default), **usage** (§7.7 → `StopInfo`), **provider swap + model identity** (§7.8, **OQ8**).
- **Error normalization** (§8): thrown error → `GenerationError`, one file per provider family; fixture-tested (§10.5); the lift rules (429/Retry-After both forms, 408/timeout→transport). **OQ5** pins built-in `LanguageModelError` case names.

**Satisfies:** G3, completes G4/G5, G8 (provider swap).
**Exit:** on-device + Claude-package mappings pass §10.5 fixtures; a real stream captured & reduced end-to-end; ⚠️ items resolved against current beta and logged in OQ tracker.
**Beta risk:** **high and expected.** This milestone re-opens each beta. Cut-line fallbacks live here (see below).

### M7 — Observable projection + `overlay_live`
The `@MainActor @Observable` read side (§6.2, §7.4, §11).

- `projection = overlay_live(reduce(persistedLog ++ unflushedTail, mapping))`, where `overlay_live` maps `.interrupted → .streaming` for in-flight `GenerationID`s only, identity otherwise.
- **P2** (overlay correctness, §10.6): live set ⊆ open generations; crash recovery is the degenerate empty-live-set case (overlay disappears → `.interrupted` shows through).
- `conversationList` on the projection (not the store actor, which exposes no synchronous reads).
- Deltas hop to main actor at *display* cadence (~a frame), independent of disk flush.

**Satisfies:** G7.
**Exit:** P2 green; streaming renders smoothly in a preview driven by `ScriptedLanguageModel`; recovery = overlay vanishing, no recovery pass.
**Beta risk:** none (pure projection over reducer output).

### M8 — Scroll demo app (the hero)
The [Scroll](../Scroll) Xcode app. DoD-1 and DoD-2.

- Chat UI driving the exhaustive `switch message.state` (§11) — the code-aesthetics showpiece.
- **Kill-and-relaunch:** kill mid-stream → relaunch → `.interrupted` with partial text; Regenerate works; the interrupted partial survives as its own branch, reachable via the branch switcher (**DoD-1**, the README hero GIF).
- **Provider swap:** `SystemLanguageModel` → Claude package with only the driver-init line changed (**DoD-2**).

**Satisfies:** G8, DoD-1, DoD-2.
**Exit:** the kill/relaunch GIF is recordable; provider swap compiles & runs with a one-line change.
**Beta risk:** medium — depends on M6 being beta-stable and on real model availability.

### M9 — README, ADR-001, tag `0.1.0`
DoD-3/4/5.

- README: 60-second quickstart, the recoverability table, the exhaustive-switch example, and the **"why not just persist `session.transcript`?"** section (§2 incumbent argument, the five-way failure — **DoD-4**).
- **ADR-001** ratified (§9, §6.1): tagged-JSON encoding, discriminator registry (tags never reused, removed tags reserved), unknown-discriminator→quarantine + tolerant-terminal exception, gap-diagnostic rule, version-frozen corpus, upcasters named as the evolution idiom.
- Full CI green: crash-fuzz (suffix + interior-gap), cancellation chaos, hostile-fixture quarantine (§6.6 row-for-row + non-rules + cascade), **P1–P3** (**DoD-3**).
- Tag `0.1.0`; pre-1.0 SemVer caveats (**DoD-5**).

**Satisfies:** DoD-3, DoD-4, DoD-5.
**Exit:** all five DoD items checked; `0.1.0` tagged.
**Beta risk:** low.

---

## Beta-verification track (runs parallel from M6 on)

Today is 2026-07-14; GA is ~Sept. Treat OQ1–9 (spec §14) as a recurring per-beta checklist, not a one-time gate. Keep an OQ tracker; each is "one spike evening, likely recurring":

| OQ | What to pin | Blocks |
|----|-------------|--------|
| OQ1 | Transcript-seeding initializer shape | M6 rehydration |
| OQ2 | Tool-activity observation surface | M6 tool records |
| OQ3 | `LanguageModel` conformance surface | M3 ScriptedModel binding |
| OQ4 | Cumulative-snapshot stream element type | M6 prefix-diffing |
| OQ5 | Built-in `LanguageModelError` case names | M1/M6 error taxonomy |
| OQ6 | Session single-flight error surface | M6 `isResponding` gate |
| OQ7 | Context/KV-cache APIs stop at session edge | §2 sherlock check (positioning) |
| OQ8 | Requested-descriptor derivability | M6 model identity |
| OQ9 | Reasoning / custom segment exposure | M6 stream handling, N11 |

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
