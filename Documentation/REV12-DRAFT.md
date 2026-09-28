# SPEC rev 12 — proposed amendments (DRAFT, for item-by-item sign-off)

**Status:** ⏳ drafted 2026-09-28 at Phase 4's open. **Nothing here has touched
`SPEC.md`.** Ratifies at the `0.1.0` tag (D67), as Appendix J.

**How to use this.** One section per inventory item (M9-PLAN §6). Each gives the
**current** text verbatim, the **proposed** replacement, and **why** — so sign-off is
per item rather than per document. This is the pattern that worked at rev 7: draft to a
scratch file, sign off item by item, *then* edit `SPEC.md` in batches, sweeping after
each batch. ⚠️ **The sweep's scope is `SPEC.md` and `ADR/` as well as `Sources/**`**
(D71) — rev 11 left two retired sentences alive precisely because the sweep ran over
sources only.

⚠️ **Delete this file at ratification.** It is scaffolding, and a draft left beside a
ratified spec is a second source of truth.

**Nothing in rev 12 touches the wire.** Every item is prose, a name, or a residue.
Recorded up front because that is the first question a reader of a spec revision asks.

---

## Item 1 — §9: retire the `ValueObservation` clause (F12)

**Current** (§9, line 653):

> **Backend: GRDB** (ADR-003, Accepted at M4) — migrations and value observation, the
> latter of which the M7 projection wants.

**Proposed:**

> **Backend: GRDB** (ADR-003, Accepted at M4) — for migrations and the single-writer
> transaction model. Database-level change observation was examined at M7 and
> **declined**: the projection is fed by the store, which already knows what changed and
> can say so in the vocabulary of the ledger rather than of the schema (ADR-003, D38/D39).

**Why.** The clause forecasts a design M7 then chose against, so it is now false in the
one direction that matters — it tells a reader the projection is wired to the database
when it is wired to the store. Paraphrased rather than quoted, so future retired-phrase
sweeps do not re-report a fixed site (the rev 9 lesson).

⚠️ ADR-003 carries the same retired sentence in its own bullet list and is amended in the
same batch (F19). That pairing is the whole reason D71 widened the sweep.

- [ ] Signed off

---

## Item 2 — §8: the zero-sentinel rule for `contextSizeExceeded` (D57, F7/F13)

**Current** (§8): the `contextSizeExceeded` paragraph explains the fields are optional
*"because the ledger records what was reported, and non-Apple providers report neither"*.
True, and it stops one step short of the rule that makes the optionality real.

**Proposed** — append to that paragraph:

> **A reported `0` is recorded as `nil`, not as zero** (D57, landed at M8). Apple's
> `ContextSizeExceeded` carries non-optional `Int`s, so a provider that measures nothing
> must still put *something* there — and `ClaudeForFoundationModels` sends `0`/`0`,
> because the Messages API reports neither. Forwarding that unchanged would record a
> context window of zero tokens **permanently**, in a log that cannot be rewritten; an
> overflow with `tokenCount: 0` is also self-contradictory on its face. So normalization
> maps `0` → `nil` on both family paths, which is what makes `nil` mean *not reported*
> rather than merely *not populated*. Classification ignores the payload (below), so this
> is a rule about what the ledger **claims**, not about what a user sees.

**Why.** M8-PLAN records this note as owed to rev 11 and it was not written. It is the
clearest example in the spec of the difference between an optional that is nominal and
one that is load-bearing, and it names the provider that proved it — which is the
standard §8 holds itself to elsewhere.

- [ ] Signed off

---

## Item 3 — Tenet 6: a language mode, not a point release (F14)

**Current** (§3, tenet 6, line 51):

> **Strict concurrency clean.** Swift 6.2, no `@unchecked Sendable` in public API,
> reduction is pure and isolated from UI.

**Proposed:**

> **Strict concurrency clean.** Swift 6 language mode, no `@unchecked Sendable` in public
> API, reduction is pure and isolated from UI.

**Why.** A tenet is a design constraint; a compiler point release is not one. Pinning
`6.2` makes the tenet read as false on every later toolchain while nothing about the
constraint has changed. ⚠️ **M9 supplied the proof rather than the argument:** the
compiler moved **6.3 → 6.4** between Phase 2 and the Phase 0 re-run, with no effect on
this tenet whatsoever. The manifest already says `swiftLanguageModes: [.v6]`, which is
the thing actually being promised.

- [ ] Signed off

---

## Item 4 — §12: the target restated on evidence (D67, F15)

**Current** (§12, line 827):

> **v0.1 — target: tagged before iOS 27 GA (~Sept).**

**Proposed:**

> **v0.1 — target: tagged against the SDK current when Phase 4 opens.** *(Was "before
> iOS 27 GA (~Sept)", which was a proxy for the real requirement and is now retired.)*
> The point was never the calendar: a `0.1.0` whose `sdkBuildIsPinned` names a superseded
> build fails its own tripwire the week it ships. ⚠️ **The proxy was falsified in the
> window it described.** macOS 27 GA shipped mid-M9, Phase 0 was re-run against it
> (2026-09-20), and the tag now follows the SDK rather than the date — which is what D67
> said to do and what "before GA" would have made impossible to satisfy honestly.

**Why.** Rewriting a target on evidence rather than deleting it, following §12's own
precedent for cut lines (annotated with outcome, not removed) — a target that was
considered and replaced is evidence about the estimate.

- [ ] Signed off

---

## Item 5 — §13 DoD-5: name the README as the pre-1.0 caveat's home (F17)

**Current** (§13 item 5):

> Tagged `0.1.0`; pre-1.0 SemVer caveats stated; …

**Proposed:**

> Tagged `0.1.0`; **the pre-1.0 caveat stated in the README** — source compatibility
> follows pre-1.0 SemVer, while the *wire* is governed by ADR-001 and the frozen corpus
> regardless of version, and the public enums are split into those a consumer may switch
> exhaustively and those that will grow; …

**Why.** "Caveats stated" does not say where, and a requirement with no home is not
checkable. Drafting the text (Phase 3) found it carried a decision nothing else in the
repo stated — **which enums may be switched exhaustively** — and that is a promise
`0.1.0` makes whether or not anyone writes it down. `PublicAPIStabilityTests` now
enforces the stable half.

- [ ] Signed off

---

## Item 6 — Illustrative names follow Phase 2

**Proposed** — a sweep, not a single edit. Everywhere §6/§11's sketches spell these:

| Old | New | Note |
|---|---|---|
| `GenerationID` | `GenerationAttemptID` | D62. ⚠️ **The wire keeps `generation` and the `"generationID"` field key** (ADR-001 R-2, permanent) and `Message` says `attemptID`. The layering is deliberate; do not make it uniform. |
| `siblings(of:)` | `versions(of:)` | D64 — inclusive and ordered, where the old one was exclusive. Deleted rather than kept for symmetry. |
| a hand-spelled `ModelDescriptor(provider: "apple", model: "system")` | `ModelDescriptor.appleSystem` | D64 — §11's driver line. |
| derived-state sketches showing `var` | `public internal(set) var`, or one sentence saying derived state is read-only to consumers | D63. |

**Why.** §1 says type names in the spec are illustrative and "bikesheddable; semantics
not" — so this is housekeeping, and cheap. It matters anyway because a reader checking
the landed API against the spec should not find four gratuitous mismatches.

⚠️ ADR-002's M1 decisions and ROADMAP's M1 record keep the **old** names, annotated with
a pointer — they are records of what was decided then, and rewriting a record makes the
change log lie (Appendix E's precedent).

- [ ] Signed off

---

## Item 7 — Toolchain fallout: **empty, twice, and recorded as such**

**Proposed** — no spec sentence changes. Add to §14's re-verification note:

> Beta 5 → Beta 6 (2026-09-05) and Beta 6 → **27.0 GA** (2026-09-20) both moved
> **nothing** in the pinned surface: `appleErrorSurface` and `consumedSurface` matched
> unmodified on each pass, with `parserIsNotVacuous` green beside them, and all four
> residues re-confirmed. Recorded because a null result is an answer, and two of them in
> a row across a beta→GA boundary is the strongest available evidence that the tripwires
> are pinning the right things.

**Why.** An absence left unwritten is re-derived by the next audit. Two live facts found
*outside* the pinned subset are noted in §8 (item 10) and needed no amendment:
`SystemLanguageModel.Adapter` is `obsoleted: 27.0`, and
`Transcript.StructuredSegment.source` is renamed `schemaName`.

⚠️ **Deliberately NOT an amendment:** N3/§7.1's "exhausted by *two* turns of roughly 2k
each" already carries "⚠️ the number is not the finding — *two turns* is". Measurements
now stand at two turns (`4098`), three (`6093`) and three (`6095`) against an unchanged
`contextSize=4096`. The claim is untouched; three turns is still a short conversation
with substantial messages, which is the point. Recorded so a future reader who measures
three does not file a correction against a sentence that was never a constant.

- [ ] Signed off

---

## Item 8 — §9 privacy: the file-protection pointer (D65)

**Current** (§9, line 658):

> File protection `.completeUntilFirstUserAuthentication` minimum; document that apps
> handling sensitive domains should layer their own encryption.

**Proposed** — append:

> **Applied by LedgerKit on the iOS family**, to the database and its sidecars
> (`FileProtectionType` is an iOS-family concept; the macOS equivalent is FileVault,
> which is not a library's to set). Two gaps are **owned rather than closed** (ADR-003,
> closed at M9 by documentation): `-wal` and `-shm` do not exist until the first write,
> so they are protected on the *next* open; and the robust answer is protection on the
> containing **directory**, which belongs to whoever chose it. No `PersistenceConfiguration`
> knob for that — it would be public API bought for a floor the app sets in one line.

**Why.** The current sentence reads as advice to the app when half of it is a thing the
library does. ⚠️ Writing the README's Privacy section is what caught this: the draft
claimed LedgerKit sets *no* protection class, which is false
(`SQLitePersistenceStore.swift:134`). A spec that stated the split plainly would have
prevented the error.

- [ ] Signed off

---

## Item 9 — §10.1: `Understudy` is a product, not a package (D61)

**Current** (§10.1, line 665): *"ship it as a separate product and let it be the gateway
drug"* — still true, and now ambiguous, because the repo has one root package vending two
products.

**Proposed** — append:

> Since D61 it is a **product of this same package**, not a package of its own. A consumer
> wanting only the double writes `.product(name: "Understudy", package: "LedgerKit")` —
> so SPM builds and links only `Understudy`, with no LedgerKit code and no GRDB. ⚠️ **But
> they must still name LedgerKit as the dependency**, which is a real cost to the
> gateway-drug positioning and was overstated in D61's draft. The honest sentence is "you
> don't *link* LedgerKit", not "you don't depend on it". A split repo's cost — two tags,
> two CI matrices, a compatibility question between them, pre-1.0 — is larger.

**Why.** "Separate product" is now load-bearing vocabulary that a reader can easily read
as "separate package", which is what it meant before D61. The cost is recorded because
the README must not repeat the draft's stronger claim.

- [ ] Signed off

---

## Item 10 — §8 provenance: PCC's quota API is unaccounted for (NEW, 2026-09-28)

**Proposed** — append to §8's provenance note (the paragraph that explains
`modelUnavailable` comes from an availability API rather than from `LanguageModelError`):

> **PCC's quota surface is Apple's too, and §8 normalizes none of it.**
> `PrivateCloudComputeLanguageModel` exposes `quotaUsage` — `{ status,
> limitIncreaseSuggestion, resetDate }`, plus `isLimitReached` and
> `Status.belowLimit(_).isApproachingLimit` — as a **pre-generation** query, structurally
> the same as `availability`. Quota is billing-adjacent and §2 puts auth/billing for
> server models in Apple's column, so an app reads it directly. LedgerKit's obligation
> begins when a generation *fails*, and the existing row discharges it:
> `Error.quotaLimitReached` → `rateLimited(retryAfter: resetDate)`. ⚠️ **No new
> `RequiredAction` case**: a quota ceiling is something an app waits out, so it is
> `retryable`, not `recoverableUpstream`, and surfacing a limit-increase prompt is the app
> reading Apple's API — the boundary working rather than a gap in it.

**Why.** Exactly the shape rev 9 fixed for `modelUnavailable`: §8 claims totality over
Apple's taxonomy, so a reader auditing that claim finds a whole quota surface unmentioned
and concludes the section is sloppy. One paragraph closes it.

⚠️ **The reason this is worth a spec sentence rather than a note.** The obvious reading of
`limitIncreaseSuggestion` is that `RequiredAction` wants a fifth case, and
`RequiredAction` is on the README's **stable** list — enums a consumer may switch
exhaustively. Writing down *why it does not* is what stops a later contributor making a
breaking change while thinking they are filling a gap.

- [ ] Signed off

---

## Item 11 — §14 gains a PCC residue (NEW, 2026-09-28)

**Proposed** — §14 currently says *"nothing here is open"*, which was true and is not.
Add:

> **One residue is open again (2026-09-28), and its arrival is the mechanism working.**
> §14 was emptied at M6 because a substrate appeared and the residues, written as tests,
> answered themselves. Private Cloud Compute is the next substrate: its entitlement has
> been requestable since the owner's Apple Developer programme acceptance, and §8's three
> `PrivateCloudComputeLanguageModel.Error` rows are **dispositions nobody has run** —
> mapped by lift rules 2 and 4, never observed.
>
> The sharpest of the three is a live contradiction in this document.
> `serviceUnavailable` is described above as *"the nil-status transient this section
> anticipated in prose"*, while the default classification maps a nil-status
> `providerFailure` to **`terminal`**. If it really is transient, the shipped affordance
> is wrong for it, and the remedy is already named: an override keyed on `code`, plus a
> fixture. **This is not a `0.1.0` blocker**, because `Recoverability` is derived at
> classification time and persisted nowhere — so the correction is free after the tag and
> retroactively upgrades historical failures.
>
> Carried as `PrivateCloudComputeResidueTests`, gated on `LEDGERKIT_PCC=1` and reporting
> *skipped* until an entitlement exists. A fourth gate rather than a reuse of
> `LEDGERKIT_DEVICE`: the substrates are independent, and folding them together would
> skip the PCC residue for the wrong reason on the only hardware that can answer it.

**Why.** §14's own argument is that a residue written as a test re-asks its question while
one written as a note decays. Reopening the section is cheaper than discovering in v0.2
that three error mappings were never verified.

⚠️ The residue deliberately does **not** mint a public `ModelDescriptor` constant for PCC.
`provider`/`model` is permanent wire data; D64 added `.appleSystem` because two apps
spelling one model differently make it look like two, which is exactly the reason not to
choose the string before anyone has run it. A static constant later is additive.

- [ ] Signed off

---

## Item 12 — Carried from Phases 1–3

- **§12's cut-line 1 and DoD-1 wording** — already reconciled at rev 11. No action;
  recorded so the next audit does not re-check.
- ⚠️ **One item is deliberately *not* here: the read-side race.** A second instance of
  the projection flake appeared on 2026-09-28 (`RecoveryTests.swift:192`, spinning on the
  exact expression it then asserts, which failed). If that is a library bug in
  `ConversationProjection`, the fix is code and possibly a §7.4/§6.2 sentence — but
  **writing a spec sentence before the mechanism is understood would be guessing in the
  contract**, which is the one place this project does not guess. It is a **Phase 4 gate
  item** (M9-PLAN §6a) and becomes a rev 12 item only if the diagnosis produces a claim
  worth binding.

- [ ] Signed off

---

## Ratification checklist (D67 order)

1. [ ] Every item above signed off
2. [ ] `SPEC.md` edited in batches, with a retired-phrase sweep over `SPEC.md`, `ADR/`
       **and** `Sources/**` after each batch (D71)
3. [ ] Appendix J written — the rev 12 change record
4. [ ] `SPEC.md` header bumped to rev 12
5. [ ] ADR-003's `ValueObservation` bullet amended in the same batch as item 1 (F19)
6. [ ] **This file deleted**
