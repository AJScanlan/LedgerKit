# M9 Implementation Plan — README, ADR-001, tag `0.1.0`

**Status:** ⏳ **IN PROGRESS** — drafted 2026-09-05 from the M8 boundary audit (same date;
findings **F1–F40** are cited by number throughout; **F41** added at Phase 0).
**Phase 0 ☑ done 2026-09-05.** **Four decisions signed off** — D61, D62, D64 and D70,
three of them with amendments recorded against the draft. **D63, D65–D69 and D71–D72 are
still Proposed** and are reviewed at the gate that lands each. **Next: Phase 1**
(hygiene — documents, the Formal model, CI, git).

**Companion to:** [ROADMAP.md](./ROADMAP.md) (M9 section — **stale as of this
draft, per F8**; rewritten at Phase 1) · [SPEC.md](./SPEC.md) §12 (target and cut
lines), §13 DoD-3/4/5, §9 (privacy floor), §10.2 (the frozen corpus) ·
[ADR-001](./ADR/ADR-001-event-encoding.md) (ratifies here) ·
[ADR-003](./ADR/ADR-003-persistence-dependency.md) (file-protection revisit) ·
[ENHANCEMENTS.md](./ENHANCEMENTS.md) · [M8-PLAN.md](./M8-PLAN.md) §7 (the seven
inherited handoffs) · the **M8 boundary audit** (2026-09-05).
**Baseline:** M0–M8 done; **457 tests green** (434 `LedgerKit` + 23 `Understudy`,
warning-free; six skips in a bare run: 2 `LEDGERKIT_RECORD`, 3 `LEDGERKIT_DEVICE`,
1 `LEDGERKIT_DEEP`). SPEC **rev 11 ratified 2026-09-05**.
**Toolchain — current as of Phase 0 (2026-09-05):** Xcode 27 **Beta 6** (`27A5252f`),
macOS 27.0 SDK `26A5419a`, host macOS `26A5425a`, iOS runtime `24A5423a`. Note this is
**Beta 6 + macOS Beta 8**, not the Beta 7 this plan was drafted against, and the host is
*ahead* of the SDK — the safe direction. (Was Beta 5 / `27A5237l` / SDK `26A5406c` /
host `26A5406e` / runtime `24A5408d` through M8.) Phase 0 was that pass, alone — the M8
Phase 0 shape, third outing, and **the first one where the beta moved nothing**.
**Spec work:** amendments open **rev 12**, ratified at the `0.1.0` tag. The inventory is
§6, seeded from the audit. The standing pattern applies — draft to a scratch file, sign
off item by item, land in batches, sweep after each batch — **with the sweep's scope
widened to `SPEC.md` and `ADR/`** (D71), because two retired sentences survived rev 11
precisely because the sweep runs over `Sources/**` only (F12, F19).

> **How to use this document.** The plan is working memory across sessions, agents
> and compactions: checkboxes and per-phase status lines are updated as work lands;
> anything that changes a decision goes in the Decision log (D-numbers are global —
> this plan continues the sequence at **D61**); deviations are recorded rather than
> silent. Each phase ends with a **review gate**: stop, run both suites, review with
> Alexander before the next phase. ⚠️ **Tick the checkboxes as items land** — M8-PLAN
> reached COMPLETE with two whole phase checklists still unticked (F1), which is the
> kind of drift the next audit then has to re-derive.

> **TL;DR.** M9 is the release milestone, and its real work is not the README. It is
> **(0)** absorbing Beta 6/7, **(1)** making the repo consumable — a root
> `Package.swift`, a LICENSE, and the last free breaking changes to the public API —
> and only then **(2)** the README and **(3)** rev 12, ADR-001 Accepted, the corpus
> freeze and the tag. The schedule risk is the beta, not the prose: a `0.1.0` tagged
> against a superseded SDK build string fails its own tripwire the week it ships
> (D67). Every phase before the tag is short; none is optional.

---

## 1. What M9 is, in one paragraph

M9 closes DoD-3, DoD-4 and DoD-5 (SPEC §13): the full suite re-confirmed green at the
tag on both substrates; a README with the 60-second quickstart, the recoverability
table, the exhaustive-switch example and the *"why not just persist
`session.transcript`?"* argument (§2's incumbent); and a tagged `0.1.0` with ADR-001
Accepted, the discriminator registry mechanically enforced (already true —
`RegistryTests`), and the version-frozen corpus populated. Underneath those three lines
sit the things the audit found nobody had scheduled: the packaging question that has
been handed forward since M6 (F36), the naming review (F23), the derived-state
mutability hole (F24), the Formal model's staleness (F30), and the toolchain pass that
Beta 6/7 now owes (F37).

**Roadmap exit criteria (the contract for "done"):**

- ☑ Both suites green on **Beta 6**, both substrates, pin moved, every tripwire finding
  dispositioned — there were none (Phase 0, 2026-09-05).
- **A remote consumer can `.package(url:from: "0.1.0")` and get both products** (D61).
- The public API changes in D62–D64 landed **with tests**, and the SPEC's illustrative
  names follow.
- README per DoD-4; LICENSE present (D66).
- Rev 12 ratified; ADR-001 **Accepted**; `Corpus/frozen/0.1.0` populated; `0.1.0` tagged
  (D67).
- ROADMAP, CLAUDE.md, ENHANCEMENTS and M8-PLAN's stale lines aligned (F1–F7, F8, F22).

---

## 2. Context that must survive compaction

| Fact | Source | Consequence for M9 |
|---|---|---|
| ~~The SDK pin is `26A5406c` (Beta 5)~~ → **`26A5419a` (Beta 6), moved at Phase 0 after the manifests re-verified clean** | `AppleErrorSurfaceTests.sdkBuildIsPinned` | ☑ done. It fired exactly as designed and found nothing, which is a result |
| ⚠️ **Two iOS 27.0 runtimes are installed** (`24A5408d`, `24A5423a`) and they share one `SimRuntime.iOS-27-0` identifier — so `-destination '…OS=27.0'` and `simctl list … \| head -1` are both nominally ambiguous | measured at Phase 0 (**F41**) | **Milder than it looks, and measured rather than assumed:** the two builds share a *single* device set, and the booted `iPhone 17 Pro` reports `SIMULATOR_RUNTIME_BUILD_VERSION=24A5423a` — the **newer**. So there is one device to pick, not two, and it is the current one. Phase 0 pinned by UDID anyway. Owner is handling the CI half; no repo action taken |
| ⚠️ **Host OS and Xcode must be on the same train** or the test process SIGSEGVs in dyld, with a stack pointing at LedgerKit code that contains nothing unsafe | M8 Phase 0, CLAUDE.md | Update macOS to Beta 7 **and** Xcode to Beta 6 together. Diagnose any crash with a ten-line repro before suspecting this repo |
| ⚠️ **CI's Xcode selection ties two 27-family Xcodes** (strict `-gt` on major, first glob wins) | M7 audit F3; audit F32; `ci.yml` | **Live now, and confirmed by reading the loop:** Beta 5 and Beta 6 both report major 27, glob order puts `Beta.5` first, and `27 -gt 27` is false — so CI would select **Beta 5** and `sdkBuildIsPinned` would pass against a stale pin. A green run verifying nothing is worse than a red one. **Owner is handling this (2026-09-05)**: CI may already select by variable or by "latest 27", pending what GitHub's runners carry. D72's selection bullet stays open until that is known |
| ~~**`GenerationID` is the only top-level name colliding with FoundationModels**~~ — **re-tested on Beta 6 at Phase 0: the collision is LIVE** | audit F23; Phase 0 probe | ☑ **D62 fires.** The `@Generable` expansion still names `GenerationID` unqualified, and it fails in a *consumer* package, not merely in this repo's test target |
| **Derived state is constructible only by reduction, but `public var` afterwards** — `message.state = .streaming(…)` compiles for a consumer | audit F24; `Core/Message.swift`, `Core/Conversation.swift` | D63. `MessageTree.rootChildren` is already `public private(set)`, which is the intent the other types missed |
| ⚠️ **A stored `activeMessages` goes stale under the overlay.** `overlay(_:live:)` rewrites states through `MessageTree.updateStates`; a `Conversation` carrying a precomputed `[Message]` would then disagree with its own tree | `Projection/Overlay.swift:40–68`; checked while drafting this plan | The audit's F26 remedy (precompute in `classify`) is **reversed** — D64 keeps it computed and documents the hoist. Recorded because the audit said otherwise |
| **The `Understudy` path dependency makes neither package remotely consumable** — `Package.swift`'s own comment says M9 must dissolve it | `LedgerKit/Package.swift`; M7/M8 handoff 1; audit F36 | D61, Phase 2, **first** — README, CI and DocC are written against the final layout |
| **Three path constants assume the current layout**: `ImportBoundaryTests` walks three `deletingLastPathComponent()`s to `Sources/`; `CorpusFile` writes record mode via `#filePath`; the app's `packageProductDependencies` were hand-patched | `ImportBoundaryTests.swift:23–27`, `CorpusFile.swift:174`, `project.pbxproj` | D61's checklist names all three. A layout move that leaves `ImportBoundaryTests` pointing at nothing reports **skipped**, not failed — the dormancy shape D36 exists to prevent, so the move must be verified by a deliberate violation |
| **The Formal model predates M8 Phase 1's restructure of `drive`** (split into slot lifecycle + `runToTerminal`, abandon catch + notify). Its whole encoding is "a PlusCal label is an `await`" | `Formal/` last touched 2026-08-15; audit F30 | Phase 1 re-transcribes and re-calibrates. `_none.cfg` and `_tombstone.cfg` **must still fail** or the model has stopped reproducing A3 |
| ~~`origin/main` is 20 commits behind; `M9` local-only; branch `M8` and tag `M8` collide~~ | audit F34, F40 | ☑ **done at Phase 0.** `main` and `M9` pushed; the `M8` **tag** turned out to be missing from the remote too and was pushed; the `M8` *branch* deleted after confirming branch, tag and `main` were all `6aaab94`. Convention question for handoff 7 survives |
| **The residues are `LEDGERKIT_DEVICE`-gated and CI never sets it** — only `concurrentRequests` runs unflagged | `ResidueTests.swift:35,125`; `ci.yml`; audit F9 | D72 decides; ROADMAP/CLAUDE.md's "re-asks on every run" is corrected either way |
| **No LICENSE, no README** | audit F38 | D66; Phase 2 and 3 |
| **The DoD-2 wiring lives on `m8-dod2-claude`** pinned to an untagged vendor revision, and forces an iOS 27 app floor | M8-PLAN D58 | D69: merge only if Anthropic tags a Beta 6-buildable release before Phase 4; otherwise cite the clip |
| **The corpus freeze is written to run *after* the tag** (`git switch --detach v0.1.0`), naming a tag the rest of the repo spells `0.1.0` | `Corpus/README.md:134–150`; audit F10, F11 | D67 flips the order and settles the spelling |
| **Two retired sentences survived rev 11 outside `Sources/`**: SPEC §9's "value observation, the latter of which the M7 projection wants" and ADR-003's bullet saying `ValueObservation` feeds `conversationList` | audit F12, F19 | Rev 12 items 1 and 8; D71 widens the sweep so the class is closed, not just the instances |
| **D57's zero-sentinel rule never reached §8** despite M8-PLAN saying it was owed | M8-PLAN D57; audit F7/F13 | Rev 12 item 2 |
| **`AppModel.descriptor` re-spells `ModelDescriptor(provider: "apple", model: "system")` by hand** because the `any LanguageModel` path cannot reach the convenience initializer's default | `AppModel.swift:112–120`; audit F27 | D64: a public constant, because those strings are durable wire data and two apps spelling them differently would make one model look like two |
| ⚠️ **"Before iOS 27 GA" is now a two-week window** with the beta unverified | SPEC §12; audit F15 | D67: tag against the SDK current at Phase 4, not a calendar date |

---

## 3. Decisions (made up front; revisit only at a review gate)

All **Proposed** at drafting; each needs owner sign-off at or before the gate that
lands it.

### D61 — Packaging: one root `Package.swift`, two products, one repo

The repo root gains a manifest declaring products `LedgerKit` and `Understudy` with
targets `Sources/LedgerKit`, `Sources/Understudy`, `Tests/LedgerKitTests`,
`Tests/UnderstudyTests`. The two per-directory manifests go away.

**Why this and not split repos.** (i) The path dependency cannot be resolved by any
remote consumer, so a `0.1.0` on today's layout is a tag nobody can depend on — this is
a DoD-5 blocker. Worse than the drafted wording implies: there is **no root
`Package.swift` at all**, so `.package(url:)` against this repo does not resolve to a
degraded package, it resolves to nothing. (ii) Split repos double the release ceremony
for a pre-1.0 pair that move together, and `Understudy`'s only consumer today is
LedgerKit's test target. (iii) SPM lets a consumer *build* against `Understudy` alone —
no LedgerKit code, no GRDB, nothing linked. (iv) The workspace and the app's hand-patched
`packageProductDependencies` re-point once.

⚠️ **Argument (iii) was overstated in the draft and is corrected here** (owner signed
off 2026-09-05). The draft said "nobody is forced to depend on LedgerKit to get the
double." That is true of the *build graph* and false of the *manifest*: a consumer
wanting only `Understudy` still writes

```swift
.package(url: "https://github.com/AJScanlan/LedgerKit.git", from: "0.1.0"),
…
.product(name: "Understudy", package: "LedgerKit")
```

— they must name LedgerKit to get it. That is a real cost to the gateway-drug
positioning (§10.1) and it does not change the decision, because a split repo's cost
(two tags, two CI matrices, a version-compatibility question between them, pre-1.0)
is larger. **But the README must not repeat the draft's claim**: the honest sentence is
"you don't link LedgerKit", not "you don't depend on it". Recorded because the
overstatement was one edit away from becoming marketing copy.

**What it preserves, and must.** `Understudy` **still does not depend on LedgerKit** —
the floor stays 26 for both targets, and `Corpus/` / `Registry/` remain test resources.
Note the enforcement gets *stronger*, not weaker, under one manifest: `Understudy`
becomes a sibling **target** declaring no dependencies, so an `import LedgerKit` inside
it fails to resolve and SPM rejects a target cycle outright — the build catches what
was previously only convention. The `ImportBoundaryTests` sibling is still worth adding,
because it catches the case the build cannot: someone *adding* the dependency to the
manifest, which compiles fine and breaks the rule silently. Point it at the manifest as
well as at the imports.

**Costs, priced.** Every `swift test --package-path …` in CLAUDE.md, CI, plans and
README becomes plain `swift test`; the three path constants in §2 move; `Package.resolved`
regenerates; the workspace references change. Split later remains possible — a
monorepo-to-split move is mechanical, the reverse is a dependency-graph change.

### D62 — `GenerationID` → `GenerationAttemptID` — **FIRES** (Phase 0 verified, owner signed off 2026-09-05)

Phase 0 re-ran the collision as a *consumer* package. **Beta 6's macro still emits the
unqualified name**, so the condition is met and the rename lands in Phase 2. The verbatim
error is in Phase 0's checklist.

**Why `GenerationAttemptID`.** Wire-neutral: the type name reaches no encoding; the
registry keys are `generation` / `generationID` and do not move (ADR-001 R-2). Keeps
ADR-002's four-type scheme and its one-minting-path rule; a `Ledger` prefix on one of
four identifiers would be the worse inconsistency. "Attempt" is the concept I7 already
reasons about — 1:1 with `MessageID` now, N:1 under continuation-resume (§12).

**Property names follow: `Message.generationID` → `Message.attemptID`.** Signed off.
`Message` carries no "generation" in its own name, so `attemptID` is unambiguous there
by the guidelines' own test, and I7 says a message has exactly one.

**The `Payload` case labels stay `generation:` — decided, not defaulted.** The owner
offered to change them too (the API is unpublished, so it is free). Declined, and the
reason is worth recording because the cheap option is the wrong one twice over:

1. **The label is not the wire key, so changing it buys nothing the wire notices.**
   `CodingKeys` are explicit (`case generationID`), so `deltaAppended(attempt:)` would
   still encode `"generationID"`. The Swift vocabulary and the permanent wire vocabulary
   would simply disagree at every site.
2. **The event *kinds* are the fixed point, and they say "generation".**
   `generationStarted(attempt:)` reads worse than `generationStarted(generation:)`, and
   renaming the kinds is not on the table — those *are* wire tags, permanently reserved
   under ADR-001 R-2.
3. **Keeping them is what makes the rename's wire-neutrality provable.** `tags.json`
   unchanged + `RegistryTests` green in both directions is the evidence that renaming a
   Swift type touched no format. Changing labels would not break that, but changing keys
   would, and the two are one edit apart — so the rule is "the type name moved, nothing
   else did", which is checkable at a glance.

So the vocabulary is deliberately layered rather than uniform: the **type** says
`GenerationAttempt` (because Apple owns `GenerationID`), the **wire** and the **events**
say `generation` (because that is the domain noun and it is permanent), and **`Message`**
says `attempt` (because that is the concept the message has one of).

⚠️ **One consequence Phase 2 must not miss:** `FoldedMessage.generationID` is internal
but `Codable`, and the snapshot encoding is *synthesized from property names*. Renaming
it moves the snapshot schema, which requires a **`reducerVersion` bump** (precedent:
M4 Phase 0 bumped to 2 for exactly this) and a `LEDGERKIT_RECORD=1` corpus re-record if
`StateDump` renders the field. Both are free by design — snapshots are
discard-on-mismatch, no migration ever — but a silent bump is how a snapshot and its
version drift apart.

**Rejected:** leave it and document the file-split workaround. Defensible, but the
failure lands inside a macro expansion the consumer did not write and cannot read, and
this is the last moment the rename is free. ADR-002 gains a §6 recording the rename and
the reason.

### D63 — Derived state is `private(set)`

Every stored property on `Conversation`, `Message`, `QuarantinedEvent` and
`ConversationSummary` becomes `public private(set) var` (or `let` where nothing in the
module mutates it). M4 Phase 0 made these types constructible only by reduction; leaving
them mutable afterwards let a consumer write `message.state = .streaming(partial:)` — a
state no fold produces — through the back door the internal initializers had just
closed. `MessageTree.rootChildren` already has this shape.

In-module mutation sites (`MessageTree.updateStates`, `Message.init(_:mapping:)`,
`classify`) are unaffected. **Test:** none can assert a compile failure, so the evidence
is the diff plus a one-line note in each type's doc. The demo (`Projection/`) must still
build — it is the acceptance test for whether any consumer legitimately mutated one.

### D64 — Three read-side conveniences; one audit recommendation reversed

1. **`MessageTree.versions(of:) -> [Message]`** — inclusive, sibling-ordered,
   virtual-root-aware: what a `‹ 2 of 3 ›` pager needs (M8 handoff 6). Body is
   `ChatScreen.versions(of:in:)` moved into the library. Tests in `MessageTreeTests`
   in place of the existing sibling cases; `ChatScreen` switches to it, which is the
   ergonomics check.

   **⚠️ `siblings(of:)` is DELETED, not kept beside it (amended 2026-09-05, owner signed
   off — this reverses the drafted plan).** Two methods differing by one element is the
   shape that makes callers pick wrong, and this pair is worse than most: `siblings`'
   own doc advertises the use case it *cannot serve* ("non-empty exactly when a branch
   switcher is warranted"), which is the friction M8 handoff 6 recorded. Pre-1.0 is the
   only moment removal is free, and keeping it means carrying a method forever to serve
   nobody. Call sites to migrate — all internal, none in the library's own `Sources/`:
   `MessageTreeTests` (5), `ConversationStoreTests` (2), `ClassifyTests` (1),
   `CorpusTests` (1), `RecoveryTests` (1), `Playground` (2). Every one reads *better*
   as versions, including the Playground's `print("branches at the answer: …")`, which
   is currently off-by-one from what a pager shows.

   **Shape decided: a plain `[Message]`, not a tuple or a bespoke collection.** The
   pager also wants the current index, and the temptation is to return
   `(versions:current:)` so the demo's `?? 0` disappears. Declined: the method's
   contract guarantees the message is present, so `firstIndex(of:)` is total in fact
   even though the type cannot say so, and a tuple return to launder one optional is
   un-Swifty and over-fits one call site. The guarantee goes in the doc comment
   instead, which is where `Conversation.activeMessages`' non-optionality already
   lives.
2. **`ModelDescriptor.appleSystem`** (name bikesheddable) — the on-device default,
   `provider: "apple", model: "system", version: nil`, used by the `SystemLanguageModel`
   convenience initializer and by `AppModel`. Durable wire strings get one spelling.
3. **`Conversation.activeMessages` stays computed.** The audit (F26) proposed
   precomputing it in `classify`; checked against `Overlay.swift`, that is wrong — the
   overlay rewrites states through `updateStates`, so a stored array would disagree with
   its own tree. The honest remedy is documentation: the doc comment and the README say
   *hoist it into a local per body evaluation*, which is what the demo does. Recorded
   here because the plan should not silently drop an audit finding it disagreed with.

### D65 — ADR-003's file-protection item closes by documentation, not by a knob

No `PersistenceConfiguration` option for directory-level protection. The two honest gaps
(sidecars protected on the *next* open; directory protection belongs to whoever chose
the directory) are properties of where the app put the file. A public knob would be API
bought for a floor the app can set in one line. README gets the sentence; ADR-003's
"Deferred to M9" paragraph becomes "Closed at M9, by documentation"; §9's privacy bullet
gains the pointer (rev 12 item 8).

### D66 — License: MIT

GRDB and SwiftStreamingMarkdown are MIT; the Claude package is Apache-2.0. MIT is the
least friction for a library that wants adopting. Apache-2.0's patent grant is the one
argument the other way; owner's call, but the plan proceeds on MIT.

### D67 — The tag: `0.1.0` (no prefix), freeze *before* tagging, against the SDK current at Phase 4

- **Spelling:** `0.1.0`, matching ROADMAP, SPEC, and the `M1`…`M8` convention; the
  corpus README's `v0.1.0` is corrected.
- **Order:** on the release-candidate commit run `LEDGERKIT_RECORD=1 swift test`, confirm
  `dev/` is clean, copy `dev/` → `frozen/0.1.0`, flip ADR-001 to Accepted, commit, **then**
  tag that commit. A consumer at the tag then holds the frozen corpus; the README's
  detach-then-copy order left it empty at the tag (F11).
- **Against which SDK:** whichever is current when Phase 4 opens. "Before GA" was a proxy
  for "usable on GA day"; a `0.1.0` whose `sdkBuildIsPinned` names a superseded beta
  fails its own tripwire the week it ships. If an RC lands mid-M9, Phase 0 repeats
  (it is designed to be cheap) and the tag waits for it. §12's target sentence is
  restated on this evidence (rev 12 item 4).
- **SemVer caveat** (DoD-5) lives in the README: pre-1.0, minor versions may break
  source; the *wire* is governed by ADR-001 and the frozen corpus regardless of version.

### D68 — D60 has no library action; the demo pacer is optional polish

§7.4 records the flush-cadence-as-display-floor as an owned limit whose remedy — pace
the display from the cumulative partial — is what `StreamingPartialSource` already
does. What M8 carried forward is only whether `comfortableBacklog` (120 chars) should be
retuned so a fast provider engages the calm cadence. That is demo polish: do it if the
README hero wants a Claude clip, skip it otherwise. Stated so "carried into M9: D60"
stops reading as an open library item.

### D69 — The DoD-2 branch merges only behind a vendor tag

If Anthropic tags a release that builds on Beta 6 before Phase 4, `m8-dod2-claude`
rebases and merges with the app on that tag. Otherwise the branch stays unmerged, the
README cites `dod2.gif` and the log line (`provider: "anthropic"`), and names the branch.
D58 unchanged; this adds the date the decision is taken.

⚠️ **Phase 0 found the first half of the condition already met, which the plan did not
expect.** `anthropics/ClaudeForFoundationModels` now carries release tags **`0.1.0`
through `0.1.4`**, where M8 recorded it as untagged and D58 refused to pin `main` to a
bare revision for that reason. `main` is unmoved at `fd965bf`. Read-only `ls-remote`
only — nothing fetched, nothing installed.

**This does not decide D69, and the distinction is the whole decision.** A tag satisfies
D58's objection (a version, not a revision); it says nothing about whether `0.1.4`
*builds against the Beta 6 SDK*, which is D69's actual condition and the thing that
broke at M8. So Phase 4 evaluates one question rather than two:

- **Does `0.1.4` build on the SDK current at Phase 4?** If yes → rebase and merge, with
  the app already at 27 (D70 paid that cost).
- If no → the branch stays unmerged and the README cites the clip, exactly as drafted.

⚠️ **Do not resolve this early.** The SDK will very likely move again before Phase 4
(D67 assumes an RC in the window), so a build check run now would be re-run anyway, and
a "yes" recorded now could be stale by the tag. Also: adding the dependency is a person's
decision (§12 cut line 4's standing rule that a remote dependency is not something this
milestone takes in passing).

### D70 — The app target moves to 27; the OS-availability gate goes

`Projection`'s deployment target is 26.5/26.4 on `main` while `ProjectionApp` refuses
anything below 27 at launch. Set the app to 27 and delete the gate; **the packages stay
at 26** and CLAUDE.md's floor rule is untouched. M8 counted the gate's vacuity under the
Claude branch as a cost; it is not, because the gate demonstrates nothing a consumer
needs. Low priority, lands with Phase 2's other app edits.

**Reasoning corrected 2026-09-05 (owner signed off), because "demonstrates nothing"
skipped the question that matters:** if the app moves to 27, what still evidences the
packages' **26 floor**? Answer, checked rather than assumed: the *package builds do*.
SPM compiles LedgerKit at `arm64-apple-macos26.0` from the manifest's `.macOS(.v26)`,
and the simulator tier compiles at `arm64-apple-ios26.0-simulator` — so both floors are
continuously verified by the two commands CI already runs. The app was never the
evidence, which is exactly why moving it costs nothing. Had the answer come out the
other way, D70 would have been wrong.

**Side benefit worth naming, since it feeds D69:** the app being at 27 already is
precisely what M8-PLAN D58 counted *against* merging `m8-dod2-claude` ("it also forces
the app's deployment target to 27"). D70 pays that cost deliberately on `main`, so it
stops being a cost the Claude branch imposes — which removes one of D69's two
objections before D69 is even evaluated.

### D71 — The retired-phrase sweep covers `SPEC.md` and `ADR/`

F12 and F19 are both retired wording that survived rev 11 because the sweep's scope is
`Sources/**`. From rev 12 on, each batch's sweep (sentence grep, noun grep, "proposed
for rev" grep) runs over `Sources/**`, `Documentation/SPEC.md`, `Documentation/ADR/`,
`ROADMAP.md` and `CLAUDE.md`. Appendices are exempt, by the standing "body paraphrases,
appendices quote" rule.

⚠️ **A third instance found at Phase 0 (F42), and it is the one that argues hardest for
this decision.** CLAUDE.md described `consumedSurface` as pinning `Transcript.Segment`
**(4)** and the channel's response actions **(7)**. Both were stale from Beta 5's
removals — the real manifest pins **3** and **6** — and rev 11 amended the three *spec*
passages citing `custom` while leaving this one, exactly because it is outside
`Sources/**`. Fixed at Phase 0 (it is a toolchain-adjacent factual claim, so it fell in
that phase's one exception).

**What makes it worse than F12/F19, and worth a rule of its own:** those two were retired
*prose*, where a reader loses nothing by not believing them. This was a **number**, and a
number is the kind of thing a reader checks a manifest *against* — so a stale one sends
someone looking for a discrepancy that does not exist, or worse, invites them to "fix"
the manifest to match the doc. **Where a document restates a machine-checked fact, it
must say which copy is authoritative.** CLAUDE.md's line now does; the sweep should treat
restated counts as first-class targets alongside retired sentences.

### D72 — CI: selection by SDK build string, an app-build job, residues on the self-hosted runner

- **Selection:** among candidates at SDK major ≥ 27, pick the greatest
  `xcrun --show-sdk-build-version` (build strings sort: `26A5388f` < `26A5406c`). Closes
  M7 audit F3 rather than waiting for it to be moot again.
- **App job:** `xcodebuild … -scheme Projection build` on the simulator job. The app is
  what Beta 5 broke first; a beta drop must fail it visibly. `ProjectionUITests` stay
  manual (40 s, flaky harness).
- **Residues:** set `LEDGERKIT_DEVICE=1` on the host job **when `CI_RUNNER` is set**
  (the dev machine has Apple Intelligence by definition); hosted runners cannot run them
  and the job already fails loudly on toolchain absence. ROADMAP/CLAUDE.md's sentence is
  corrected to say exactly which residues run where.
- With D61, both `swift test` invocations collapse to one.

---

## 4. Guardrails for M9

M5–M8's carry forward. M9 adds:

1. **Breaking changes land in one phase (Phase 2) and nowhere else.** This is M4 Phase
   0's argument, last outing: after the tag, every one of D62–D64 costs consumers a
   migration. Anything breaking discovered later in M9 goes through a logged decision.
2. **The README is written against the shipped layout and the shipped names**, never
   against a layout Phase 2 has not landed. Quickstart code is compiled — copy it from
   `AppModel.swift` and the Playground, both of which build.
3. **No new public API without a test and a SPEC illustrative-name refresh**
   (`versions(of:)`, `appleSystem`).
4. **The demo consumes public API only** (M8 guardrail 1) — and after D63 it is also the
   proof that no consumer needed to mutate derived state.
5. **Nothing merges from `m8-dod2-claude` except under D69.**
6. **`grep -rn "GenerationDriver(" Projection/` → 1** (M8 guardrail 3) still holds at the
   tag.

---

## 5. Phases

Phase 0 is the beta, alone. Phase 1 is hygiene (docs, model, CI, git). Phase 2 is the
breaking changes. Phase 3 is the README. Phase 4 is rev 12, ADR-001, the freeze, the tag.

---

### Phase 0 — Toolchain: Xcode 27 Beta 6 + macOS 27 Beta 8 (zero repo changes, priced exception)

**Status:** ☑ **done 2026-09-05.** **457 green** (434 `LedgerKit` + 23 `Understudy`) on
the host across device *and* deep tiers, 434 green on the iOS 27 simulator, app builds,
UI tests run. **Exactly one failure before the pin moved, and it was the pin.** No repo
change beyond the pin and CLAUDE.md's toolchain lines.

**Goal:** the suite green on the new toolchain with every tripwire finding dispositioned
and nothing else changed, so every failure is attributable to the beta — the M8 Phase 0
shape. ⚠️ M8 taught that "zero repo changes" bends when a beta breaks the *build*; if it
does, the repairs land first, are recorded as findings (D56a's precedent), and are the
only exception. **It did not bend here.**

> **The beta was quieter than the one before it, and that is the recordable result.**
> Beta 5 broke `Understudy`'s build, silently killed two metadata reads, removed a
> `Transcript.Segment` case and a channel action, and SIGSEGV'd the host suite in dyld.
> **Beta 6 moved nothing at all**: `appleErrorSurface` and `consumedSurface` both matched
> unmodified, `Understudy` built and passed 23/23 first time, and all four §14 residues
> re-confirmed. Two consecutive betas, opposite outcomes, and no amount of reasoning
> would have predicted which — which is the whole argument for the tripwires rather than
> for a discipline. ⚠️ **A null result is only a result because `parserIsNotVacuous`
> passed beside it**; without that companion, "Apple changed nothing" and "the parser
> found nothing" are the same green tick.

- [x] `git push origin main M9` (F34) — `origin/main` was 20 commits behind and is now
      current; `M9` pushed. Local branch `M8` **deleted** (F40) after confirming branch,
      tag and `main` all pointed at `6aaab94`. The `M8` **tag was not on the remote** and
      is now pushed.
- [x] **Toolchain installed** — and it is **Beta 6 + macOS Beta 8**, not the Beta 7 this
      plan drafted against. Host is *ahead* of the SDK, which is the safe direction
      (M8's dyld crash was the reverse). Recorded — Xcode 27.0 Beta 6 **`27A5252f`**;
      macOS 27.0 SDK **`26A5419a`** (was `26A5406c`); host macOS 27.0 **`26A5425a`**
      (was `26A5406e`); iOS runtime **`24A5423a`** (was `24A5408d`, and **both are
      installed** — F41).
- [x] `swift test` both packages. **Exactly one failure, `sdkBuildIsPinned`** — the
      predicted one, and the only one. `Understudy` 23/23. No §6 item 7 entry needed.
- [x] Both manifests re-verified against the Beta 6 `.swiftinterface` — **unchanged**,
      and the tripwires are reading the *right* file: they resolve it through
      `xcrun --show-sdk-path`, which follows `xcode-select` (Beta 6), so the pass is not
      a stale read of the Beta 5 still installed beside it. No M4-PLAN §2 / M6-PLAN §2a
      citation is touched. Pin moved `26A5406c` → `26A5419a` with the reason in its doc.
- [x] **F23 re-tested — D62 fires.** A throwaway *consumer* package (`.package(path:)`
      at `LedgerKit/`, a file importing both modules with a `@Generable` struct) fails to
      build on Beta 6. Verbatim:

      ```
      error: 'GenerationID' is ambiguous for type lookup in this context
        |  var id: GenerationID     ← inside the macro's PartiallyGenerated expansion
      FoundationModels.GenerationID:3:15: note: found this candidate
      LedgerKit.GenerationID:1:15:       note: found this candidate
      ```

      The macro still emits the bare name. Worth noting the probe was built as a
      *consumer* rather than as a file in this repo: that is the shape the failure
      actually lands in, and it removes any doubt that the test target's own arrangement
      was masking or manufacturing it.
- [x] `LEDGERKIT_DEVICE=1 LEDGERKIT_DEEP=1` — **all four residues re-confirmed** on real
      hardware, and the deep tier green beside them. Measured on Beta 6:
  - **§7.7, input total inclusive of cached** — `input.total=81 cached=0 output.total=19`
    with `usage.total=100 == 81+19`, so the cache is counted once. Same conclusion rev 9
    reached, reached again by the aggregate rather than by the warm/cold invariance.
  - **N3, the on-device budget** — **still 4096** (`contextSize=4096`, with `tokenCount`
    `4098` and `6093` across the two runs).
  - **§7.3, provider revisions** — **0 across 248 snapshots** of 8 generations
    (116 + 132). Cumulative with M6's 412, that is **660 snapshots and no revision**;
    the fail-loud path remains unreachable end-to-end and remains.
  - **§7.2, `concurrentRequests` thrown** — green unflagged, as always: the check belongs
    to the session, not to a model, so it is substrate-independent.

- [x] Simulator tier on the **new** iOS runtime — `434 tests … passed`, `TEST SUCCEEDED`.
      Pinned by UDID rather than by `OS=27.0` for F41's reason. The surface suite reports
      *skipped* there by design, so the pin is not checked on this tier.
- [x] `xcodebuild … -scheme Projection build` → `** BUILD SUCCEEDED **`, which is also
      the `SwiftStreamingMarkdown` branch-pin check passing. `ProjectionUITests`:
      **6 tests, 0 failures** (`Executed 6 tests, with 0 failures`, ~73 s) — no sign of
      the harness flakiness D72 cites as the reason to keep them out of CI, though one
      clean run is not evidence against it.
- [x] **`anthropics/ClaudeForFoundationModels` now has release tags** — `0.1.0` …
      `0.1.4`, where M8 recorded it as untagged. `main` is unmoved at `fd965bf`. **This
      changes D69's input** — see the decision, which is now conditional on
      *buildability* rather than on a tag existing. Nothing installed.
- [x] CLAUDE.md's toolchain lines (Xcode build, `.swiftinterface` path, pin value) — the
      one repo exception, as at M8. ⚠️ The path line is now written as
      `` `xcrun --show-sdk-path`/… `` rather than a versioned `/Applications/…` path,
      because a pasted versioned path is exactly what would have made this Phase 0 a
      stale read. **Also fixed here: F42** — the same file's `consumedSurface`
      parenthetical said `Transcript.Segment` (4) and response actions (7) where the
      manifest pins **3** and **6**, both stale since Beta 5. It qualifies as a
      toolchain-line fix, and it is evidence for D71 (see there).

**Review gate:** ☑ both suites green on Beta 6 across host, device, deep and simulator
tiers; ☑ app builds; ☑ pin moved; ☑ no drift, so §6 item 7 is **empty and recorded as
such**; ☑ F23's result recorded and D62 decided; ⚠️ **Beta 5 deliberately NOT deleted
yet** — Phase 1's D72 needs two Xcodes present to verify the selection loop, and deleting
it now closes the only window (the plan filed the deletion here and the verification
there, which cannot both happen).

---

### Phase 1 — Hygiene: the audit's document findings, the Formal model, CI, git

**Status:** ⏳ **in progress 2026-09-05.** Documents aligned; the Formal model
re-verified (and the re-transcription turned out to be unnecessary — see below); CI
deferred to the owner.

**Goal:** every document says what is true today, the store's model is re-calibrated
against the store's current shape, and CI can survive a second Xcode.

- [x] **M8-PLAN staleness (F1–F6).** All **17** unticked boxes ticked with a one-line
      evidence note each — and verified against the source first rather than ticked on
      the strength of the milestone being marked COMPLETE, which is F1's lesson pointing
      the other way. Phase 0's "Gate status" paragraph rewritten (it said *blocked* and
      *outstanding* about conditions that cleared the same week). D53's status cell
      corrected — it read **awaiting a decision** while its own decision cell recorded
      the resolution twice over. D56's read **owner action pending** months after the
      action was taken. ⚠️ **F5's `~~` was worse than the audit recorded:** it opened at
      D57's table row and closed six lines later, so it struck **D57, D58, D59 and D60**
      — four live decisions, including the one D60 that rev 11 amended §7.4 for — along
      with the procedure paragraph it meant to retire. Moved to cover the paragraph
      alone.
- [x] **D59's verdict (F6) — accepted by the owner 2026-09-06.** Both keyboard-dismissal
      changes stand; M8-PLAN's status cell records the acceptance and its date. Held open
      rather than inferred from the behaviour having shipped in both DoD recordings,
      because a decision log that reads silence as assent stops being evidence.
- [x] **ENHANCEMENTS entry 1** gains M7's pricing evidence *against* (F22) — and M8's
      too, since the demo's branch pager also declined a whole-tree walk. Two consumers
      have now not wanted it; the honest reading is that **export is not merely the
      natural slot, it is the only demand anyone has found.**
- [x] **ROADMAP M9 section** rewritten from this plan (F8) — it was a four-bullet sketch
      that understated the milestone badly. Beta-verification track's CI sentence
      corrected (F9) in **both** places it appears. The **target line** restated on D67's
      evidence ("before iOS 27 GA" → against the SDK current at the tag) and the
      critical-path diagram updated. Tag spelling (F10) was **already aligned** in
      ROADMAP — the only `v0.1.0` in the repo is `Corpus/README.md`, which D67 corrects
      at Phase 4 together with the procedure's order; splitting that one paragraph across
      two phases would invite two edits to it.
- [x] **CLAUDE.md**: skip count is six, not five. Residue/CI sentence corrected (F9) —
      it now says exactly which residue runs unattended (`concurrentRequests`, because
      its check belongs to the session) and which three do not. Plus **F42**, found while
      reviewing Phase 0's diff.
- [x] **Formal (F30) — re-verified, and the re-transcription was not needed.**
      All four configs reproduce their recorded results exactly on Java 26:
      `none` **FAILS** `NoOrphanRows` (377 states, 51 left), `tombstone` **FAILS** (586,
      58), `sticky` passes exhausted (954, 0), `guard` passes exhausted (1044, 0).
      `pcal.trans` produced a **byte-identical** file, so the checked-in translation was
      never behind its PlusCal. **Calibration intact.**

      ⚠️ **F30's premise was wrong, and the reason generalizes.** The audit reasoned from
      the diff — M8 restructured `drive`, so the model of `drive` must be stale — but the
      restructure is entirely inside the region this model deliberately collapses. Its
      state is four variables (`convExists`, `rows`, `live`, `deleting`); `abandon(_:in:)`
      writes `shownPartials` and calls `notify`, **neither of which is modelled**, and
      `release` is unchanged, so an abandonment and a normal termination are the *same
      transition*. **A model is stale when its abstraction stops matching, not when the
      code changes** — and the cheap test is "did a modelled variable change, or did an
      `await` appear or vanish at a labelled point", which took two functions to answer.
      Written into `Formal/README.md` along with what *would* invalidate it, so the next
      audit has a test rather than an instinct.
- [ ] **CI (D72) — deferred to the owner (2026-09-05).** They are already changing the
      Xcode selection (a variable, or "latest 27") and are checking what GitHub's runners
      carry, so a concurrent edit here would collide. The other two parts stay open and
      are independent of that: an **app-build step** (the app is what Beta 5 broke first,
      and CI does not build it) and **`LEDGERKIT_DEVICE=1` when `CI_RUNNER` is set**.
      ⚠️ **The selection bug is live on this host right now** — Beta 5 and Beta 6 both
      report SDK major 27, glob order puts Beta 5 first, and `-gt` keeps it, so CI would
      select **Beta 5** and `sdkBuildIsPinned` would pass against a stale pin. Beta 5 is
      therefore **still installed**, so the loop can be tested against two Xcodes when
      this is picked up.
- [x] **ADR-003 self-contradiction (F19):** the "Why GRDB fits" `ValueObservation` bullet
      struck, with a pointer to the document's own "Settled at M7" section. Kept as a
      strike rather than deleted — GRDB was chosen partly *for* a feature later turned
      down, and silently removing the reason would misreport why the decision was taken.
- [x] `LoadedEvent`'s doc gains the reconciliation with `QuarantinedEvent.init`'s (F29).
      The resolution is the derived-state rule's **scope**: a `LoadedEvent` is
      reduction's *input* and a `QuarantinedEvent` its *output*, so fabricating the first
      asserts nothing while fabricating the second would claim a reduction that never
      ran. It is also forced — a public entry point cannot take an internal element type.
      No code.

**Review gate:** documents aligned ☑; TLC re-calibrated with `_none`/`_tombstone` failing
and `_guard` passing ☑ (and the re-transcription shown unnecessary, with the reasoning
recorded); suites green ☑ — nothing here moved a test; **D59 accepted 2026-09-06** ☑;
**CI (D72) still to be verified against two Xcodes, with the owner** ☐ — the one item
carried out of this phase.

---

### Phase 2 — The breaking changes, while they are free

**Status:** ☐ not started.

**Goal:** the repo is consumable and the public API is the one `0.1.0` will carry.
Ordered so each step's tests run against the previous step's layout.

- [ ] **D61 — root `Package.swift`.** Move `LedgerKit/Sources/LedgerKit` →
      `Sources/LedgerKit`, `Understudy/Sources/Understudy` → `Sources/Understudy`, tests
      likewise; delete the two manifests; write the root one (products `LedgerKit`,
      `Understudy`; GRDB `from: "7.9.0"`; resources `Corpus`, `Registry`;
      `swiftLanguageModes: [.v6]`; floors 26). Re-point the workspace and the app's
      `packageProductDependencies` (treat `project.pbxproj` as load-bearing; back it up).
      Fix the three path constants (§2). **Verify `ImportBoundaryTests` still *runs*** by
      temporarily adding `import FoundationModels` to a `Core/` file and watching it
      fail — a skipped suite after a layout move is exactly D36's dormancy.
      Add the `Understudy`-must-not-import-LedgerKit sibling test. `swift test` at the
      root runs both targets; record the count (expect 457 + the new test).
- [ ] **D61 — consumability proof.** From a throwaway package *outside* the repo,
      `.package(path:)` at the repo root and import both products; then, after the tag,
      repeat with `.package(url:from:)`. The first is Phase 2's gate; the second is
      Phase 4's.
- [ ] **D62 — rename. Phase 0 said so; this is not conditional any more.**
      `GenerationID` → `GenerationAttemptID`; `Message.generationID` → `attemptID`;
      **`Payload` case labels stay `generation:`** and **`CodingKeys` stay
      `generationID`** (D62's three reasons). `Wire`/`Registry` unchanged — the
      `RegistryTests` both-directions check is the proof the wire did not move, so
      **`tags.json` must not change**, and if it does the rename went too far.
      ADR-002 gains §6. Retire `ToolStub.swift`'s workaround comment — but **keep the
      file split**, since the comment's *finding* (a macro expansion the author never
      wrote) is what justified the rename and the file is its worked example.
- [ ] **D62's snapshot consequence — do not let this be silent.** `FoldedMessage`'s
      field renames too, its `Codable` is synthesized from property names, so the
      **snapshot schema moves**: bump `LedgerSchema.reducerVersion` (2 → 3) in the same
      commit, and **not** `payloadVersion` — they fail in opposite directions and merging
      them is the mistake `LedgerSchema`'s doc exists to prevent. Then
      `LEDGERKIT_RECORD=1 swift test` and confirm the only `dev/` churn is the field
      name. A snapshot whose version did not move with its schema is a stale checkpoint
      that *decodes*, which is the one failure mode discard-on-mismatch cannot catch.
- [ ] **D63 — `private(set)`** across the four derived types. Demo still builds.
- [ ] **D64 — `versions(of:)` in, `siblings(of:)` out.** Tests: inclusive (the message
      is always a member); ordered (matches `children(of: parent)`, or `rootChildren` at
      root level); root-level via `rootChildren`; unknown ID → empty.
      **The property that replaces `siblings == versions − self`, and is stronger than
      it:** *the version set is a property of the position, not of the member* — for any
      two members `a`, `b` of one group, `versions(of: a) == versions(of: b)` — swept
      over every message of every corpus fixture. The old property could be satisfied by
      a method that computed the group differently per member; this one cannot.
      Migrate the 12 `siblings(of:)` call sites (D64.1 lists them). `ChatScreen` adopts
      the library method and deletes its own copy, which is the ergonomics check.
- [ ] **D64 — `ModelDescriptor.appleSystem`** used by the `SystemLanguageModel`
      convenience init and by `AppModel`; a test asserts the convenience init's default
      **is** the constant, so the two spellings cannot drift into naming one model twice.
      `activeMessages` doc comment: the hoist advice (D64.3).
- [ ] **D66 — `LICENSE`** (MIT) at the root; `Package.swift` needs nothing.
- [ ] **D70 — app target 27, gate removed.** `ProjectionUITests` green.
- [ ] Sweep `Sources/**`, SPEC, ADRs, ROADMAP, CLAUDE.md for the old names and the
      `--package-path` idiom (D71's scope). SPEC's illustrative names follow in rev 12
      (item 6), not here.
- [ ] Mutation pass, the standing rule: drop `versions(of:)`'s root-level branch (test
      must fail); reorder its result (test must fail); make `appleSystem` differ from the
      convenience default (test must fail).

**Review gate:** suites green on both substrates at the new layout; the outside-the-repo
consumer resolves both products; demo builds and its UI tests pass; every breaking
change has its test and its mutation logged; Alexander signs off the API diff — this is
the last review before those names are permanent.

---

### Phase 3 — README (DoD-4) and, if the budget allows, DocC

**Status:** ☐ not started.

**Goal:** the document a stranger reads first, written against the shipped layout.

- [ ] **README** sections, in this order: one-paragraph positioning (§1); the hero GIF
      (`dod1.gif`) with a two-sentence caption saying what the log shows; **60-second
      quickstart** (root `Package.swift` dependency line; `ConversationStore`; the driver
      line; `send`; `ConversationProjection`; the exhaustive `switch` — lifted from
      `AppModel.swift`/`MessageBubble.swift`, so it compiles); the **recoverability table**
      (§8's default mapping, verbatim); **"Why not just persist `session.transcript`?"**
      (§2's five-way argument, DoD-4); the one-line provider swap with `dod2.gif` and the
      log line, plus D69's branch note; testing with `Understudy` (the gateway drug — its
      own short section, no LedgerKit assumed); requirements (Xcode 27, floors 26,
      27-gated `Session/`); the privacy floor sentence (D65); **pre-1.0 caveat** (D67);
      license.
- [ ] Every code block in the README is pasted from something that builds; note the
      source file beside each in a comment.
- [ ] **DocC (ENHANCEMENTS 2) — stretch.** Two articles if time allows: the recovery
      story written against `RecoveryTests.killMidStreamRecoversAsInterrupted` (M7
      handoff 4's unflushed-tail arithmetic), and the transcript-blob argument shared with
      the README. `Understudy` gets its own catalog or nothing. **Cut first if Phase 4 is
      at risk** — DocC is not in §13.

**Review gate:** README read cold by Alexander; every snippet compiles; DoD-4's four
named items present.

---

### Phase 4 — Rev 12, ADR-001 Accepted, the freeze, the tag

**Status:** ☐ not started.

- [ ] **Re-run Phase 0 if the SDK moved** since (an RC is likely in this window). D67:
      the tag is against the current SDK.
- [ ] §6's inventory finalized; draft to a scratch file; item-by-item sign-off; land in
      batches with the widened sweep (D71) after each.
- [ ] **ADR-001:** status → **Accepted**; ADR README index updated; the "Open — to decide
      before M9" heading becomes "Closed"; `R-3`'s registry inventory re-read against
      `tags.json` one last time.
- [ ] **ADR-003:** file-protection paragraph → closed by documentation (D65).
- [ ] **Freeze (D67):** on the release-candidate commit, `LEDGERKIT_RECORD=1 swift test`
      → confirm `dev/` clean → `cp -R Tests/LedgerKitTests/Corpus/dev …/frozen/0.1.0` →
      `CorpusFileTests`' frozen sweep now has rows (assert it is non-empty from here on,
      so the freeze cannot be silently lost) → correct `Corpus/README.md`'s procedure and
      tag spelling.
- [ ] **DoD-3 re-confirmation at the candidate:** full suite both substrates, device
      tier, deep tier; `grep GenerationDriver( Projection/` → 1.
- [ ] Commit; **tag `0.1.0`** (annotated); push tag; repeat the D61 consumability proof
      with `.package(url:from: "0.1.0")` from outside the repo.
- [ ] **Alignment:** ROADMAP M9 struck through against exit criteria — **check the header
      line explicitly**; DoD table rows 3–5 ticked with dates; CLAUDE.md status rewrite
      (layout, commands, counts, toolchain, names); M9-PLAN status → COMPLETE **with every
      checkbox ticked** (F1's lesson).
- [ ] §8 coverage traceability filled; §9/§10 logs closed; §7 handoffs to v0.2 verified
      against what landed.

**Review gate:** `0.1.0` resolves remotely with both products; all five §13 items
checked; rev 12 ratified; ADR-001 Accepted; `frozen/0.1.0` populated and asserted
non-empty.

---

## 6. Rev 12 inventory (seeded from the audit; draft at Phase 4, not from memory)

1. **§9** — retire "migrations and value observation, the latter of which the M7
   projection wants" (F12). Paraphrase, do not quote: GRDB for migrations and the
   single-writer transaction model; observation examined and declined at M7 (ADR-003).
2. **§8** — `contextSizeExceeded`: a reported `0` is recorded as `nil` — a context window
   of zero is not a measurement any model can produce — with the provider that proved it
   named (D57, F7/F13).
3. **Tenet 6** — "Swift 6 language mode, strict concurrency", not a point release (F14).
4. **§12** — the target restated on evidence: tagged against the SDK current at the tag;
   "before GA" was a proxy (D67, F15).
5. **§13 DoD-5** — the README named as the home of the pre-1.0 caveat (F17).
6. **Illustrative names** — whatever Phase 2 lands: `GenerationAttemptID` (if D62 fires),
   `versions(of:)` beside `siblings(of:)` where §6.4 mentions the branch switcher,
   `ModelDescriptor.appleSystem` in §11's driver line, `private(set)` shown in §6.2's
   sketch (a one-word change per field, or a sentence saying derived state is read-only).
7. **Beta 6 fallout — ☑ EMPTY, and recorded as such** (Phase 0, 2026-09-05). Nothing in
   Apple's surface moved between SDK `26A5406c` and `26A5419a`: `appleErrorSurface` and
   `consumedSurface` both matched unmodified, `Understudy` built first time, and all four
   §14 residues re-confirmed. **No spec sentence changes.** This is the legitimate answer
   the item anticipated, and it is written down rather than left as an absence, so the
   next audit does not re-derive it.

   ⚠️ **One observation that is deliberately *not* an amendment.** N3/§7.1 say the
   on-device window is "exhausted by **two** turns of roughly 2k each", with an explicit
   "⚠️ the number is not the finding — *two turns* is". Phase 0's two device runs
   exhausted it in **two turns (`tokenCount=4098`) and three (`6093`)** respectively —
   the count varies with how much the model happens to generate, while the **budget is
   unchanged at 4096**. The spec's *claim* is untouched: three turns is still a short
   conversation with substantial messages, which is the whole point ("not an edge case
   that bites eventually"). Recorded so a future reader who measures three does not file
   a correction against a sentence that was never a constant.
8. **§9 privacy** — one pointer: directory-level protection is the app's, closed at M9
   by documentation (D65).
9. **§10.1** — `Understudy` is a product of the same package (D61); the "separate
   product" sentence stays true, the "separate package" reading does not.
10. **Anything Phases 1–3 surface** — logged here as discovered.

**Considered and not amended (record so the next audit does not re-derive):** D60/§7.4
(already an owned limit — D68); `activeMessages` (a convenience, not a contract — D64.3);
the demo's dependency costs (M8 handoff 7 — not spec matter).

---

## 7. Explicit handoffs (to v0.2 — recorded so they aren't lost)

1. **ENHANCEMENTS 1** (whole-tree traversal) — still deferred, now with M7's evidence
   against written into the file. Natural slot: export.
2. **ENHANCEMENTS 3** (third-party `GenerationDriving` testability) — `GenerationRequest`
   still has no public constructor; price when a real third-party driver exists.
3. **D60 / §7.4** — a display flush distinct from the durability flush was declined for
   v0.1; if a second provider's chunking makes the demo's pacer look wrong on camera, that
   is the evidence to reopen it.
4. **`emptyResponse` vs `decodingFailure`** (§8 watch-note) — split when guided generation
   arrives.
5. **`StopInfo.resolvedModelID`** is the home if `SystemLanguageModel.Variant` ever gains
   a stable identifier (rev 11 watch-note).
6. **The DoD-2 branch** — whichever way D69 went, the date and the vendor revision are in
   §9's log; revisit at the first v0.2 planning session.
7. **Milestone tags versus milestone branches** — `M8` collided (F40). Decide a convention
   before `M10`/v0.2 opens.
8. **DocC**, if Phase 3 cut it.

---

## 8. Coverage traceability (fill at Phase 4)

| Obligation | Suite / evidence | Status |
|---|---|---|
| Beta 6: suite green, pin moved, drift dispositioned | full run + `AppleErrorSurfaceTests` | ☑ **457 green** (434 + 23); pin `26A5406c` → `26A5419a`; **drift empty**, recorded at §6 item 7 |
| Residues re-asked on Beta 6 | `ResidueTests` under `LEDGERKIT_DEVICE=1` | ☑ all four re-confirmed — budget still 4096; 0 revisions in 248 snapshots; input total inclusive of cached; `concurrentRequests` thrown |
| Deep tier re-run on Beta 6 | `LEDGERKIT_DEEP=1` | ☑ green (four-generation generated sweep, ~23 s) |
| Gated tier on the new iOS runtime | `xcodebuild test … -scheme LedgerKit` on `24A5423a` | ☑ 434 passed, `TEST SUCCEEDED` |
| Demo app builds; UI tests run | `xcodebuild … -scheme Projection` | ☑ `BUILD SUCCEEDED`; `ProjectionUITests` **6 tests, 0 failures** |
| F23 re-tested on Beta 6 | Phase 0 record | ☑ **collision live** — D62 fires; verbatim error in Phase 0 |
| Formal model re-calibrated (`_none`/`_tombstone` fail, `_guard` passes) | Phase 1 TLC log | ☐ |
| Root package resolves for an outside consumer (path, then URL at tag) | Phase 2 / Phase 4 throwaway package | ☐ |
| `ImportBoundaryTests` still runs after the move (deliberate violation fails) | Phase 2 mutation | ☐ |
| `Understudy` never imports LedgerKit | new boundary test | ☐ |
| `GenerationAttemptID` rename is wire-neutral | `RegistryTests`; `tags.json` unchanged | ☐ / n.a. |
| Derived state read-only | diff; demo builds | ☐ |
| `versions(of:)` inclusive/ordered/root-aware; `siblings == versions − self` over the corpus | `MessageTreeTests` + mutations | ☐ |
| `appleSystem` equals the convenience default | test + mutation | ☐ |
| LICENSE present | root | ☐ |
| README: quickstart, recoverability table, exhaustive switch, transcript-blob argument | Phase 3 review | ☐ |
| Rev 12 ratified; sweep run over the widened scope | Phase 4 sweep log | ☐ |
| ADR-001 Accepted; ADR-003 closed | diff | ☐ |
| `frozen/0.1.0` populated and asserted non-empty | `CorpusFileTests` | ☐ |
| DoD-3 at the candidate, both substrates | full run | ☐ |
| `0.1.0` tagged, resolves remotely | `git tag`; outside consumer | ☐ |

---

## 9. Decision log

| # | Decision | Status |
|---|---|---|
| D61 | **Packaging: one root `Package.swift`, two products, one repo.** There is no root manifest at all, so a tag on today's layout resolves to nothing — a DoD-5 failure; split repos double release ceremony for a pair that move together. `Understudy`'s no-LedgerKit rule becomes a target-graph fact *plus* a boundary test. Costs: every `--package-path` idiom, three path constants, the workspace, the app's hand-patched dependencies. ⚠️ **Argument (iii) corrected:** a consumer taking `Understudy` alone does not *link* LedgerKit but must still *name* it in their manifest — the README must not claim otherwise | **Accepted** 2026-09-05 (owner) |
| D62 | **`GenerationID` → `GenerationAttemptID`; `Message.generationID` → `attemptID`; `Payload` labels and `CodingKeys` unchanged.** Wire-neutral, and `tags.json` staying byte-identical is the proof. Keeps ADR-002's four-type scheme; "attempt" is I7's concept. ⚠️ Carries a `reducerVersion` bump, because `FoldedMessage`'s synthesized snapshot encoding moves with the property name | **Accepted** 2026-09-05 — **condition verified live on Beta 6 at Phase 0** |
| D63 | **Derived state is `private(set)`** on `Conversation`, `Message`, `QuarantinedEvent`, `ConversationSummary` — closing the mutation back door M4 Phase 0's internal initializers left open. Blast radius is small by construction (no public API *consumes* a `Conversation`, so today a consumer can only mislead themselves locally) and the cost is zero — which is the argument for doing it now rather than the argument against bothering: it is free today and source-breaking after the tag | **Accepted** 2026-09-06 (owner) |
| D64 | **`MessageTree.versions(of:)` replaces `siblings(of:)` (deleted, not kept beside it); `ModelDescriptor.appleSystem`; `activeMessages` stays computed** — the audit's precompute remedy reversed on inspection of the overlay, and the drafted "keep both methods" reversed because `siblings`' own doc advertises the use case it cannot serve | **Accepted** 2026-09-05 (owner), amended from the draft |
| D65 | **ADR-003 file protection closes by documentation, no knob** | **Proposed** 2026-09-05 |
| D66 | **License: MIT.** GRDB and SwiftStreamingMarkdown are MIT; Apache-2.0 is Apple's convention for `swift-*` but not the third-party Swift ecosystem's, and MIT is the least friction for a library that wants adopting | **Accepted** 2026-09-06 (owner) |
| D67 | **Tag `0.1.0` (no prefix); freeze before tagging; against the SDK current at Phase 4; SemVer caveat in the README** | **Proposed** 2026-09-05 |
| D68 | **D60 has no library action; the demo pacer is optional polish** | **Proposed** 2026-09-05 |
| D69 | **DoD-2 branch merges only behind a vendor tag that builds on the SDK current at Phase 4**; otherwise cited, not merged. ⚠️ Phase 0 found `ClaudeForFoundationModels` now tags `0.1.0`–`0.1.4`, so D58's "untagged" objection is gone and **only buildability remains open** — evaluated at Phase 4, not before, since the SDK will likely move again | **Proposed** 2026-09-05; input changed at Phase 0 |
| D70 | **App target 27, OS gate removed; packages stay 26.** Reasoning corrected: the 26 floor's evidence is the *package* build targets (`arm64-apple-macos26.0`, `arm64-apple-ios26.0-simulator`), which CI already runs — the app was never the evidence, which is why moving it costs nothing. Side benefit: removes one of D58's two objections to the Claude branch | **Accepted** 2026-09-05 (owner) |
| D71 | **The retired-phrase sweep covers `SPEC.md`, `ADR/`, `ROADMAP.md`, `CLAUDE.md`** (appendices exempt) | **Proposed** 2026-09-05 |
| D72 | **CI: Xcode selection by SDK build string; app-build step; `LEDGERKIT_DEVICE=1` when `CI_RUNNER` is set** | **Proposed** 2026-09-05 |

## 10. Status log

| Date | Phase | Tests | Note |
|---|---|---|---|
| 2026-09-05 | **Plan drafted** at the M8 boundary | 457 (434 + 23) + 6 `ProjectionUITests` | Drafted from the M8 boundary audit (F1–F40). Twelve decisions proposed (D61–D72), all awaiting owner sign-off. One audit recommendation reversed during drafting (F26 → D64.3: a stored `activeMessages` goes stale under the overlay). Phase 0 is Beta 6/7 and decides D62; Phase 2 carries every breaking change; the tag waits for the SDK current at Phase 4, not the calendar |
| 2026-09-05 | **Phase 0 done** — Xcode 27 Beta 6 (`27A5252f`), SDK `26A5419a`, host `26A5425a`, iOS runtime `24A5423a` | **457 green** (434 + 23) host incl. device + deep · 434 green iOS sim · 6 `ProjectionUITests` · app builds | **The beta moved nothing.** Exactly one failure before the pin moved, and it *was* the pin; both surface manifests matched unmodified; all four §14 residues re-confirmed. §6 item 7 is empty and recorded as such. Git hygiene done (F34/F40): `main` +20 and `M9` pushed, `M8` tag pushed (it was missing too), `M8` branch deleted. **D62 fires** — the `@Generable` collision reproduces on Beta 6 in a *consumer* package. Four decisions signed off: D61 (with argument (iii) corrected — you don't *link* LedgerKit, but you do name it), D62 (`GenerationAttemptID` / `attemptID`; payload labels and `CodingKeys` deliberately unchanged; carries a `reducerVersion` bump), D64.1 amended (**delete** `siblings(of:)` rather than keep both), D70 (with the floor-evidence question answered rather than assumed). New findings: **F41** (two iOS runtimes, one device set, resolves to the newer — milder than it looked) and **F42** (CLAUDE.md's `consumedSurface` counts were stale at 4/7 where the manifest pins 3/6 — a *third* instance of D71's class, and the first where the stale thing was a **number** rather than prose, which is worse because a number invites someone to "fix" the manifest to match the doc). **D69's input changed**: the Claude package now tags `0.1.0`–`0.1.4`, so D58's untagged objection is gone and only buildability remains. ⚠️ Beta 5 **not** deleted: D72's selection loop needs two Xcodes present |
| 2026-09-05 | **Phase 1 — documents, the Formal model** (CI deferred to the owner) | 457 green, unchanged — nothing here moved a test | **The Formal model needed no re-transcription, and why is the finding.** F30 reasoned from the diff (M8 restructured `drive`) but the restructure sits entirely inside the region the model collapses: `abandon(_:in:)` writes `shownPartials` and `notify`, neither of which is a model variable, and `release` is unchanged — so an abandonment and a termination are the same transition. All four configs reproduce exactly (377/586/954/1044; `none` and `tombstone` still FAIL `NoOrphanRows`), and `pcal.trans` output was byte-identical. **A model is stale when its abstraction stops matching, not when the code changes.** M8-PLAN's 17 unticked boxes ticked after verifying each against source; F5's `~~` turned out to strike **four live decisions** (D57–D60), not just the retired paragraph; D53 and D56 status cells contradicted their own decision cells. ROADMAP's M9 section rewritten from a four-bullet sketch; its target line restated on D67. F9 corrected in both places. ADR-003's `ValueObservation` bullet struck against its own M7 section. ENHANCEMENTS 1 now carries evidence *against* from two consumers. ⚠️ Outstanding: **D59's verdict** (needs the owner — shipped unremarked is not reviewed) and **CI's D72** (owner is mid-change; Beta 5 kept installed so the loop can be tested against two Xcodes) |
