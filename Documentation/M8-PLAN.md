# M8 Implementation Plan — the `Projection` demo app (the hero)

**Status:** ☐ **DRAFTED 2026-08-16** at the M7 boundary, from the M7 boundary
audit (same date). No phase started.

**Companion to:** [ROADMAP.md](./ROADMAP.md) (M8 section) · [SPEC.md](./SPEC.md)
§11 (the sketch and the showpiece switch), §13 DoD-1/DoD-2, §12 (cut lines),
N3/§7.1 (the 4096-token budget), §8 (the affordance table the demo renders) ·
[M7-PLAN.md](./M7-PLAN.md) §7 (the five inherited handoffs) · the **M7 boundary
audit** (2026-08-16), whose findings F1–F5 are Phases 0–1 and whose rev 11
candidates seed §6.
**Baseline:** M0–M7 done and audited; **452 tests green** (429 `LedgerKit` + 23
`Understudy`, warning-free, both substrates) on **Xcode 27 Beta 4** (27A5228h,
SDK build 26A5388f). SPEC **rev 10 ratified 2026-08-16**.
**Toolchain event:** **Xcode 27 Beta 5 is out** and is Phase 0's whole subject —
the pinned SDK build will fail by design, and the audit found one operational
hazard in how CI selects between two installed 27-family Xcodes.
**Spec work:** amendments open **rev 11**, which ratifies at the M8 boundary.
The inventory is §6 — seeded from the audit, including one item **already
decided** (cut line 1 retired, owner sign-off 2026-08-16). The standing pattern
applies: draft to a scratch file, sign off item by item, land in batches, and
run the `Sources/**` retired-phrase sweep after each batch — **now with two new
greps** (§5 Phase 4), because the audit caught both classes escaping the old one.

> **How to use this document.** The plan is working memory across sessions,
> agents and compactions: checkboxes and per-phase status lines are updated as
> work lands; anything that changes a decision goes in the Decision log
> (D-numbers are global — a bare "D44" means the same thing in every plan, and
> this plan continues the sequence at **D50**); deviations are recorded rather
> than silent. Each phase ends with a **review gate**: stop, run both packages'
> suites, and review with Alexander before starting the next.

> **TL;DR.** M8 turns `StreamingPreview` into the real demo app (DoD-1 and
> DoD-2) — but it opens with two phases that make the ground true first.
> **Phase 0 is Beta 5, alone**: nothing in the repo changes, so every failure is
> the beta's doing — the tripwires finally firing for their intended reason —
> and it ends with Beta 4 deleted so neither CI nor `xcode-select` can silently
> keep testing the old toolchain. **Phase 1 is the audit's findings**, the
> significant one being F1: an abandoned generation (rev 8's "couldn't record"
> path) sticks `.streaming` on an attached projection forever, because the feed
> implements only the append-driven half of D39 and the prune keeps exactly the
> wrong entry. The demo must not be built on a read side that can stick. Then
> the app (Phase 2), the two DoD demonstrations (Phase 3), and rev 11 (Phase 4).
> Beta risk is **medium and front-loaded**: Phase 0 absorbs it or surfaces it.

---

## 1. What M8 is, in one paragraph

M8 is the hero artifact (G8, DoD-1, DoD-2): a chat app over the full stack —
`ConversationListProjection` for the list, `ConversationProjection` per
conversation, the exhaustive `switch message.state` as the visible showpiece —
persisted to real SQLite so that killing the app mid-stream and relaunching
shows `.interrupted` with the partial, Regenerate works, and the interrupted
partial survives as its own branch reachable via the branch switcher (**the
README hero GIF**). The provider swap is one line in one file, demonstrated
against a second real provider. M8 is also the milestone that absorbs **Xcode
27 Beta 5**: the surface tripwires re-verify the SDK, the residue suite re-asks
its behavioural questions, and any drift is dispositioned as a rev 11 item
rather than discovered later.

**Roadmap exit criteria (the contract for "done"):**

- **The kill/relaunch GIF is recordable** — and recorded at least once (DoD-1;
  M9 polishes the take, M8 proves the flow).
- **Provider swap compiles & runs with a one-line change** against a second
  real provider (DoD-2 as restated in rev 10; D53 names the provider after the
  Phase 1 spike).
- **The suite is green on Beta 5, both substrates**, with the SDK pin moved and
  every tripwire finding dispositioned.
- **Phase 1's audit fixes landed with the tests that would have caught them**
  (the D30 pattern, fourth outing).
- SPEC **rev 11 ratified** at the boundary (§6's inventory).
- Carried from M7 (owner-agreed 2026-08-16): **the "streaming renders smoothly"
  eyeball check** — M7's one open exit item — closes in Phase 0.

---

## 2. Context that must survive compaction

| Fact | Source | Consequence for M8 |
|---|---|---|
| **The SDK build pin is `26A5388f` (Beta 4)** and `sdkBuildIsPinned` fails on any other toolchain — *by design*; the fix is one line **after** the surface manifests re-verify | `AppleErrorSurfaceTests.swift:434`; CLAUDE.md | Phase 0. Expect exactly this failure on Beta 5; **every additional failure is a finding to disposition, not noise** |
| ⚠️ **CI's Xcode selection compares SDK *major* only, with strict `-gt`** — two 27-family Xcodes tie, the tie keeps the first glob match, and `Beta.4` sorts before `Beta.5`. Side-by-side installs mean CI silently keeps testing Beta 4 | M7 audit F3; `.github/workflows/ci.yml` | Phase 0 **deletes Beta 4 once Beta 5 is green** (owner-agreed 2026-08-16: one toolchain, no ambiguity, and the loop is fine for the next major) |
| **F1 mechanism:** on rev 8's "couldn't record" path the store throws with no terminal, `release` runs, and **no notification is sent** — `.changed` publishes only from `foldForward`, which a failed append never reaches. The projection's `pruneLiveSet` keeps any entry whose classified state is `.interrupted`, which an abandoned generation is *forever* — so an attached projection shows `.streaming` for a dead generation until its view is torn down, while a fresh attach correctly shows `.interrupted`. D39's own text names the gap: `.changed` fires when "the live set moved", and the release-without-terminal move is unnotified. Riders: `shownPartials` leaks on the same path, and two comments justify the absence wrongly | M7 audit F1; `ConversationStore.swift:1167,1212`, `ConversationProjection.swift:287` | Phase 1, D50. **Fix before the demo is built on it** — the demo's whole pitch is that the state machine never lies |
| **Feed causality is the licence for D50's prune:** a generation's `.delta`s all precede the `.changed` that retires it (FIFO per subscriber, notify synchronous with the state change) — so an entry dropped at a `.changed` cannot be re-added by a stale queued delta | `StoreFeedTests.feedOrderingIsCausal`; M7-PLAN Phase 2 | The abandon `.changed` inherits the same argument; the mutation that matters is dropping the notify, not reordering it |
| **DoD-2's provider is PCC** (rev 10, §13) — and its demonstrability is an **unprobed empirical claim**. Availability is advisory (§14): `.available` does not promise generation works, and the ledger's own history says affordance claims must be measured | SPEC §13, §14; M7 audit F5.2 | Phase 1 spikes it (~10 lines) **before** any GIF planning. If PCC declines, the fallback is Alexander's call at the gate (D53) |
| **The 4096-token budget** (rev 9): two ~2k turns exhaust the on-device window | SPEC N3, §7.1 | **Decided (D54, owner 2026-08-16): short turns for the scripted GIF; keep the `.reduceContext` affordance bubble** (already in the showpiece switch); no compaction wiring in the demo |
| **The skeleton exists and runs**: `Projection/Projection/StreamingPreview.swift` — M8 *styles* it, not replaces it. Two non-obvious inheritances: the app target's `packageProductDependencies` were **hand-patched** into `project.pbxproj`, and the script needs its **pacing** (`.wait` steps) or the framework coalesces everything into one snapshot | M7-PLAN handoff 1 | Phase 2. Treat `project.pbxproj` as load-bearing |
| **`.inMemory` → `.sqlite(at:)` is the one line** that makes DoD-1 demonstrable — the preview deliberately cannot show recovery | M7-PLAN handoff 4; `StreamingPreview.swift:97` | Phase 2 (D52 picks the location) |
| **`Harness.send` swallows the throw channel** (`try?`) — fine for a preview, wrong for the demo: §11's "one channel for couldn't-record, one for recorded failure" is half the pitch | M7 audit F5.6; **owner-approved fix 2026-08-16** | Phase 2, D55: render `LedgerError` (alert for `persistenceFailure`, disabled-send state for `generationInFlight`) |
| **`GenerationID` collides with `FoundationModels.GenerationID` inside `@Generable` expansions** — relevant only if the demo declares tool arguments; the worked example is `Tests/…/ToolStub.swift` (keep `@Generable` types in a file that does not import LedgerKit) | CLAUDE.md; M7-PLAN handoff (M9 #2) | Phase 2 imports FoundationModels beside LedgerKit for the swap line — plain references are fine; only demo *tools* would trip this |
| **Cut line 1 is retired** (owner 2026-08-16): "hide the branch-switcher UI" would falsify DoD-1's GIF, and the switcher is cheap now (`siblings(of:)` + `switchBranch` exist and are tested; `RecoveryTests.interruptedPartialSurvivesRegeneration` automates the flow) | M7 audit F5.1 | Rev 11 item 2 lands the §12 edit; ROADMAP's copy follows |
| ⚠️ **The simulator harness can die mid-run**: `** TEST FAILED **` with a long failing list and **zero `✘` lines** is the harness restarting, not a regression — the named suite passes in isolation and a clean re-run passes | M7-PLAN Phase 1 flake note | M8 does more simulator work than any milestone; recognize the signature before chasing ghosts |
| **The M7 eyeball item is open**: "streaming renders smoothly" needs a human tapping Send — everything else about the preview is test-asserted | ROADMAP M7 exit (🟨) | Phase 0 closes it (owner-agreed home, 2026-08-16); doubles as the app-builds-on-Beta-5 check |
| CLAUDE.md cites the Beta 4 `.swiftinterface` path and toolchain build — both dangle the moment Beta 4 is deleted | CLAUDE.md (Commands section) | Phase 0 updates those two lines at the switch; the full status rewrite still waits for ratification, as always |

---

## 3. Decisions (made up front; revisit only at a review gate)

### D50 — The abandoned-generation remedy: notify on abandon; prune against the store's live set

Two halves, one per layer, and both are needed:

1. **Store:** on the couldn't-record path — any throw out of `drive`'s body,
   which is post-append by definition — clear `shownPartials[generation]` and
   publish `.changed(conversation)` before rethrowing. This is the **"live set
   moved" half of D39**, which the M7 implementation never needed on the happy
   path because the terminal's own append carried it. Ordering note that the
   implementation must preserve and state: the catch body runs before `drive`'s
   `defer { release }`, and **nothing suspends between them**, so no subscriber
   can act on the notification until the slot is released — the same
   absence-of-a-suspension argument `foldForward` already documents (D38).
   Reused case rather than a new one: `StoreNotification`'s "derive it from the
   base" argument *extends* here — the base alone cannot say "abandoned", but
   base + live set together can, and that conjunction is exactly what the
   re-pull reads.
2. **Projection:** `pruneLiveSet` becomes a conjunction — keep an entry iff the
   classified state is `.interrupted` **and** the generation is in the store's
   live set (the re-pull already reads `storeLive`; pass it in). Verified
   against every race in the audit: just-started (present + interrupted →
   kept), just-finished before release (present + terminal → dropped, log
   wins), just-finished after release (absent + terminal → dropped), abandoned
   (absent + interrupted → **dropped**, the new case). A stale queued `.delta`
   cannot resurrect a dropped entry, by feed causality (§2's row).

**Owned consequence, to be stated in rev 11 item 1 rather than hidden:** when
the abandonment lands, the shown text visibly *shrinks* to the flushed prefix.
That is correct — the unflushed tail was never durable, and this is §7.4's
recovery granularity made visible while the process happens to be alive.
Claiming the tail survived would lie about what a relaunch will show.

### D51 — Demo architecture: one app model owns the store and the driver line; screens own their projections

An `@MainActor @Observable` app model owns the `ConversationStore` (opened
once, at launch) and a `driver()` factory that is **the only place in the app a
provider is named** — DoD-2's one line must be one line *in one findable
place*, and the skeleton already establishes the pattern. Screens create their
own projections (`ConversationListProjection` in the list, a
`ConversationProjection` per open detail view) in `.task`/init, because
projections are derived and deletable (tenet 2) and a screen owning its own is
the shape D42 declined a facade *for*. `isDeleted` drives navigation back from
a deleted conversation (M7 handoff 5). The Harness pattern survives as the
detail screen's model: thin, no conversation state of its own, verbs in,
projection out.

### D52 — The database lives in Application Support; the library's protection floor is the demo's answer

`.sqlite(at:)` under
`URL.applicationSupportDirectory/LedgerKit/demo.sqlite` (created with
intermediate directories). The library already applies
`.completeUntilFirstUserAuthentication` on the iOS family (ADR-003's owned
limitation notes the `-wal`/`-shm` first-open gap); the demo adds nothing,
deliberately — a demo that layered its own encryption would imply the library
needs it for ordinary use, which §9 does not claim. The directory choice is the
app's job exactly as ADR-003 says it is.

### D53 — DoD-2's provider: PCC, pending the Phase 1 spike — fallback is an owner decision made on evidence

The demonstrable second provider is `PrivateCloudComputeLanguageModel` (rev 10,
§13). **Open until the spike runs**, because demonstrability is an empirical
claim: availability is advisory (§14), and this project has twice measured an
affordance assumption and found it false. The spike is ~10 lines on the Beta 5
host: check `availability`, run one short generation, record what §8's PCC rows
actually receive. If PCC generates: D53 closes, Phase 3 proceeds. If it does
not: the gate presents the evidence and the options — check whether the current
ring now carries the Claude package (a person's decision, per cut line 4's
record), or restate DoD-2 once more — and Alexander chooses. What the plan does
*not* do is discover this the evening of the recording.

### D54 — The 4096 budget: short turns; the affordance bubble stays; no compaction wiring

**Accepted (owner, 2026-08-16).** The scripted GIF uses short turns and never
approaches the window. On-device runs keep turns short too. The
`.reduceContext` affordance bubble ("Shorten the conversation") stays in the
exhaustive switch — it costs nothing, and its *presence* is the demo of §8's
contract — but no compaction pass is wired: N3 is v0.3's, and a demo that
half-implemented it would demo the wrong thing. If a live on-device run hits
the window during development, the bubble rendering is the correct outcome, not
a bug.

### D55 — The throw channel is rendered, not swallowed

**Accepted (owner, 2026-08-16).** The demo replaces the skeleton's
`try? await store.send(…)` with a catch that renders `LedgerError`:
`persistenceFailure` → alert (the disk is the user's problem to know about);
`generationInFlight` → nothing beyond the already-disabled Send (the state was
prevented, which is the point); `unknownConversation`/`unknownMessage`/
`ineligibleTarget`/`unsupportedTarget` → alert with the case's message
(unreachable through this UI, and *rendering* them is how we notice if that
ever stops being true); `CancellationError` → ignored (pre-start cancel is
Swift convention, §7.2). One channel for "couldn't record" — now visible —
and one for "recorded a failure" — the bubbles. That pairing is §11's pitch,
and the demo should show both halves.

---

## 4. Public-API ergonomics guardrails for M8

M5/M6/M7's guardrails carry forward. M8 adds:

1. **The demo consumes public API only** — no `@testable`, anywhere, ever. The
   demo is the acceptance test for the API's ergonomics; every place it fights
   the library is a **finding for M9's API review**, recorded in §7's handoffs,
   not worked around silently and not fixed by widening the API mid-milestone.
2. **The exhaustive switch keeps no `default`** — in any screen that renders
   `MessageState` or `Recoverability`. The compiler forcing the app to handle
   interruption is the showpiece; a `default:` would demo its absence.
3. **The provider is named in exactly one line** (D51). Code review for Phase 2
   checks this mechanically: `grep -rn "LanguageModel(" Projection/` should
   find one construction site.
4. **No library changes ride the demo.** Phase 1 is where library fixes land,
   with tests; if Phase 2 or 3 surfaces a library defect, it goes through a
   logged decision — the M7 pattern (D46–D49) — never a quiet edit.

---

## 5. Phases

Phase 0 is the beta, alone. Phase 1 is the audit's fixes and the one spike.
Phase 2 is the app. Phase 3 is the two DoD demonstrations. Phase 4 closes the
milestone and ratifies rev 11.

---

### Phase 0 — Toolchain: Xcode 27 Beta 5 (zero repo changes, one exception)

**Status:** ☐ not started

**Goal:** the suite green on Beta 5 with every tripwire finding dispositioned —
and *nothing else changed*, so every failure is attributable to the beta. This
is the run the weekly CI schedule exists to simulate; this time it is real.

- [ ] Install Xcode 27 Beta 5; `sudo xcode-select -s` to it. Do **not** remove
      Beta 4 yet — it is the rollback until the suite is green.
- [ ] `swift test --package-path LedgerKit` and `--package-path Understudy`.
      **Expected: exactly one failure, `sdkBuildIsPinned`.** Every additional
      failure is a Beta 5 finding: an `appleErrorSurface`/`consumedSurface`
      mismatch is an SDK surface change (a §8/§7 decision, never a manifest
      edit); an `Understudy` *build* failure is a `LanguageModel`/
      `LanguageModelExecutor` protocol change (the §14 reopen condition);
      a `ResidueTests` failure is a behaviour that moved. Disposition each as
      a rev 11 item 3 entry before touching anything.
- [ ] Re-verify the two manifests against the Beta 5 `.swiftinterface` (the
      tests do this mechanically — read their output, then re-read any M4-PLAN
      §2 citation a change touches, per the standing re-read rule), then move
      the pin: `sdkBuildIsPinned`'s one line, with the new build string.
- [ ] `LEDGERKIT_DEVICE=1 swift test --package-path LedgerKit` — the residue
      suite re-asks its four behavioural questions on the new beta. Also run
      `LEDGERKIT_DEEP=1` once.
- [ ] The simulator tier on Beta 5's iOS 27 runtime (`xcodebuild test …
      LedgerKit` scheme). ⚠️ Remember the harness-death signature (§2) before
      chasing a long failure list with no `✘` lines.
- [ ] `xcodebuild … -scheme Projection build` — the app target builds on
      Beta 5 (the hand-patched `project.pbxproj` survives the toolchain move).
- [ ] **The carried M7 eyeball check (owner):** launch the preview in the
      simulator, tap Send, watch the scripted stream arrive over ~4 s.
      "Streaming renders smoothly" closes here — M7's last open exit item.
- [ ] **Delete Beta 4** (owner-agreed 2026-08-16). One toolchain, no ambiguity:
      CI's major-version tiebreak (audit F3) never gets the chance to pick the
      stale install, locally or on a runner. The loop itself is untouched — it
      is correct again the moment only one 27-family Xcode exists.
- [ ] The one repo exception: update CLAUDE.md's **two toolchain lines** (the
      Beta 4 `.swiftinterface` path and the Xcode build string), which dangle
      the moment Beta 4 is gone. The full CLAUDE.md status rewrite still waits
      for ratification, as every milestone's has.

**Review gate:** both suites green on Beta 5 (host + simulator + device tier +
deep tier), pin moved, any surface/behaviour drift written into §6 item 3 with
its disposition, Beta 4 gone, eyeball closed. **If drift required a §8
decision, it is signed off here, not embedded silently in the manifest.**

---

### Phase 1 — Hygiene: the M7 audit's findings + the PCC spike (tier 1)

**Status:** ☐ not started

**Goal:** the read side cannot stick (F1/D50), the two comment findings are
fixed, and D53's empirical question is answered — before any UI is built on
top.

- [ ] **F1 — the store half (D50.1):** in `drive`, catch any throw out of the
      body, clear `shownPartials[generation]`, `notify(.changed(conversation))`,
      rethrow. Comment states the no-suspension-before-release invariant
      (D38's argument, third appearance). Covers all three couldn't-record
      doors: a failed delta flush, a failed terminal in `windDown`, and a
      persistence failure in the rehydration read.
- [ ] **F1 — the projection half (D50.2):** `pruneLiveSet(against: storeLive)`
      — keep iff classified `.interrupted` **and** present in `storeLive`.
      Update the prune's doc: the two-ends split (store's view adds the
      just-started; the prune retires the just-finished *and now the
      abandoned*).
- [ ] **F1 — the comment riders:** `shownPartials`' "cleared when the
      generation winds down" gains the abandon path;
      `windDown`'s "truest account" justification is replaced with the real
      reason (the clear must follow the terminal append, and the abandon path
      has its own clear now).
- [ ] **F1 — tests (the D30 pattern):** tier 1, `ScriptedDriver` + the
      write-hostile store double (M5's per-throw-condition harness), projection
      attached: fail a mid-generation flush → assert the projection reaches
      `.interrupted` carrying the **durable prefix** (the visible shrink is the
      assertion, not a tolerance); fail the terminal in `windDown` → same;
      fresh-attach agreement stays green (regression). **Mutations:** drop the
      store's abandon notify (test must hang/fail — this is F1 itself); revert
      the prune conjunction (test must fail); note honestly that
      clear-vs-notify order is unobservable (no suspension) and claim nothing
      for it.
- [ ] **F2 — `GenerationDriving.swift` session-cache comments** (lines 31,
      116): reword to allowance-plus-reality per §7.8 rev 10 — v0.1 rebuilds
      per generation; a reuse cache is legal headroom with its own validity
      rule. Line 116 is on a **public** symbol; it goes first.
- [ ] **F4 — three "Proposed for rev 9" comments** in
      `NormalizeAppleErrors.swift` (~209, ~225, ~268) → "landed rev 9",
      matching line 200's spelling in the same file.
- [ ] **The PCC spike (D53):** ~10 lines against the Beta 5 host —
      `PrivateCloudComputeLanguageModel` availability, one short generation,
      and what §8's PCC error rows actually receive if it fails. Scratch probe
      first (the M6 pattern); promote to a device-gated test only if it earns
      permanence. Record the result verbatim in this plan's status log.

**Review gate:** suites green with the new tests, both substrates; mutations
recorded; **D53 resolved** — PCC confirmed, or the fallback decision made by
Alexander on the spike's evidence. D50's remedy confirmed against the audit's
race table.

---

### Phase 2 — The demo app (UI over public API, `ScriptedLanguageModel`-driven)

**Status:** ☐ not started

**Goal:** the real app — list, chat, branch switcher, throw channel — running
against the scripted provider on any Mac, styled from the skeleton M7 left.

- [ ] **App model (D51):** owns the store (opened once at
      `Application Support/LedgerKit/demo.sqlite` per D52, `.sqlite(at:)` —
      the one-line change handoff 4 named) and the `driver()` factory — still
      the only line naming a provider.
- [ ] **Conversation list screen:** `ConversationListProjection`; create
      (`createConversation`), rename (`setTitle` via a dialog), delete (swipe,
      `deleteConversation`), navigate to detail. Empty-state view for a fresh
      install.
- [ ] **Chat screen:** the styled `StreamingPreview` — real `TextField` input
      replacing the canned prompt, send/stop, the **exhaustive switch with no
      `default`** (guardrail 2), the streaming caret, the diagnostics badge
      kept (a demo that hid quarantine residue would hide the reducer's most
      interesting sentence).
- [ ] **Branch switcher:** at any message with non-empty `siblings(of:)`, a
      switcher affordance (chips or a menu) driving
      `switchBranch(to:in:)`. This is DoD-1's "reachable via the branch
      switcher" — the reason cut line 1 is retired, so it is not optional.
- [ ] **Deletion navigation:** `isDeleted` pops the detail screen (M7 handoff
      5) — delete from the list while the detail is open and nothing throws at
      anybody.
- [ ] **Throw channel rendered (D55):** the catch replacing `try?`, per the
      decision's per-case table.
- [ ] **Regenerate** on assistant messages (skeleton's affordances carry), and
      **edit** on user messages *as a stretch goal only* — the GIF does not
      need it, and G2's branching is already demonstrated by
      regenerate-as-sibling plus the switcher.
- [ ] **Simulator drive-through** (headless verification before the gate's
      human one): launch, create a conversation, send, watch `.streaming`,
      stop, regenerate, switch branches, delete — asserting screen state at
      each step.

**Review gate:** the app runs the full loop in the simulator against
`ScriptedLanguageModel`; guardrail 3's one-provider-line grep passes; any API
friction encountered is written into §7's M9 handoff list. A human (Alexander)
drives it once.

---

### Phase 3 — DoD-1 and DoD-2: the kill, the GIF, the swap

**Status:** ☐ not started

**Goal:** the two Definition-of-Done demonstrations, witnessed and recorded.

- [ ] **The kill/relaunch flow, live:** sqlite persistence, send with the paced
      script, **kill the app mid-stream** (terminate the process, not the
      generation), relaunch → the message renders `.interrupted` with the
      flushed partial (the three-name table read right-to-left, on a screen);
      Regenerate → new sibling; the switcher reaches the interrupted partial.
      `RecoveryTests` is this flow's automated sibling — the live run is the
      same assertions with eyes.
- [ ] **Record the GIF** (`xcrun simctl io <device> recordVideo`, then convert;
      keep the raw take). M9 owns the polished cut; M8 proves recordable and
      banks one usable take. Script the take: short prompt, visible stream,
      kill at mid-word, relaunch, the interrupted bubble, regenerate, switch.
- [ ] **DoD-2, the swap:** change the one `driver()` line to the D53 provider
      with an explicit descriptor; build; run; one real generation on screen.
      Then swap back. Record what §8 normalization produced if anything failed
      — provider-mapping churn is gold (§8's closing note).
- [ ] **On-device pass:** the same app over `SystemLanguageModel.default` on
      the host — short turns per D54. If the window is hit anyway, the
      `.reduceContext` bubble rendering **is** the correct demo (D54).

**Review gate:** GIF exists and is watchable; the swap ran against a real
second provider (or D53's fallback, as decided); both DoD lines in §13 are
demonstrably true. The healthy-log property over every log the demo wrote —
including the killed ones — stays green.

---

### Phase 4 — Wrap-up: rev 11 ratification + alignment

**Status:** ☐ not started

- [ ] §6's inventory finalized; draft to a scratch file; item-by-item
      sign-off; land in batches with the per-batch `Sources/**` sweep.
      **The sweep gains two greps** (M7 audit F2/F4, the escapee classes):
      `grep -rn "proposed for rev"` (the code's own forward-looking markers,
      which ratification obsoletes), and a grep for each retired claim's
      **nouns** (e.g. "session cache"), not only its sentence — paraphrases
      escaped the verbatim sweep once already.
- [ ] Rev 11 ratified at the boundary; Appendix I written (map to rev 10 per
      the standing appendix pattern).
- [ ] **Alignment:** ROADMAP M8 struck through against exit criteria — **check
      the header line explicitly** (stale at two of the last four boundaries;
      accurate at M7's); cut line 1's retirement mirrored in ROADMAP's copy;
      CLAUDE.md status rewritten after ratification (new test counts, Beta 5
      toolchain, the demo's existence, D50's feed change).
- [ ] Handoffs to M9 (§7) verified against what actually landed; API-friction
      findings from Phase 2 folded into M9's review list.
- [ ] §8 coverage traceability filled; §9/§10 logs closed.

---

## 6. Rev 11 inventory (amendments M8 expects — draft at Phase 4, not from memory)

Seeded from the M7 boundary audit (2026-08-16); extend as phases surface more.
Item 2 is **already decided** and awaits only the wording pass.

1. **§7.4 / §9 / §11 — the read side after "couldn't record"** (pairs with
   Phase 1, D50). Rev 8 defined the channel (throw, no terminal, generation
   reduces `.interrupted`); rev 10 defined the attached read side; neither
   milestone owned their composition, and the audit found the seam: an
   attached projection was never told, and showed `.streaming` for a dead
   generation until its view died. The amendment states the observable
   promise only (the feed stays internal, per Appendix H's deliberate
   silence): *a projection attached through a recording failure converges to
   `.interrupted` carrying the durable prefix — the unflushed tail is exactly
   what the failure cost, made visible (§7.4's recovery granularity, live).*
2. **§12 — cut line 1 retired** (owner sign-off 2026-08-16). Its invocation
   would falsify DoD-1's GIF ("reachable via the branch switcher"), and the
   switcher is cheap now — the price that justified the line expired when M7
   landed `siblings(of:)`/`switchBranch` tested. Annotate retired-with-reason
   (the cut-line list's own precedent: line 4's invoked-with-outcome).
   ROADMAP's copy follows.
3. **Beta 5 fallout** (placeholder; Phase 0 fills or strikes it). Any SDK
   surface change is a §7/§8 decision recorded here; any behaviour drift from
   the residue suite likewise; M4-PLAN §2 citations re-verified where touched.
   May legitimately end empty — say so if so.
4. **Anything Phases 1–3 surface** — logged here as discovered. Candidates the
   audit primed: DoD-2 wording if D53's spike forces a fallback; any §11
   sketch drift the demo's API friction exposes.

---

## 7. Explicit handoffs (recorded so they aren't lost)

**To M9 (README, ADR-001, tag `0.1.0`)** — inherited from M7 §7, plus M8's:

1. The packaging question (root `Package.swift` vs split repos), now with the
   demo app's hand-patched `packageProductDependencies` as a third dependent.
2. `GenerationID` ↔ `FoundationModels.GenerationID` naming review (ADR-002
   territory, not a passing decision).
3. ADR-001 ratifies at M9; ADR-003's file-protection revisit; the ENHANCEMENTS
   backlog (entry 1 carries M7's pricing evidence *against*; entry 2 — DocC —
   is M9's, with the recovery article written against `RecoveryTests`).
4. `MessageTree.updateStates` and `Message.visibleText` placement — one look
   during the API review; neither is public.
5. **New at M8:** the GIF asset (raw take + location) for the README hero;
   the API-friction list from Phase 2 (possibly empty — say so if so); the
   demo as the README's quickstart source (its app model is the 60-second
   example §13 DoD-4 wants).

---

## 8. Coverage traceability (fill at Phase 4)

| Obligation | Suite / evidence | Status |
|---|---|---|
| Beta 5: suite green, pin moved, drift dispositioned | full run + `AppleErrorSurfaceTests` | ☐ |
| Residues re-asked on Beta 5 | `ResidueTests` under `LEDGERKIT_DEVICE=1` | ☐ |
| F1: abandoned generation converges to `.interrupted` on an attached projection (flush-failure and terminal-failure doors) | new Phase 1 tests | ☐ |
| F1: the store's abandon notify — mutation caught | Phase 1 mutation log | ☐ |
| F1: prune conjunction — mutation caught | Phase 1 mutation log | ☐ |
| F2/F4 comment corrections | diff | ☐ |
| D53: PCC generates (or fallback decided on evidence) | spike record in §10 | ☐ |
| DoD-1: kill/relaunch flow live over sqlite; GIF recorded | Phase 3; `RecoveryTests` as the automated sibling | ☐ |
| DoD-2: one-line swap runs against the D53 provider | Phase 3 | ☐ |
| Throw channel rendered (D55) | Phase 2 UI + drive-through | ☐ |
| Exhaustive switch keeps no `default` | guardrail 2 review | ☐ |
| One provider-construction line in the app | guardrail 3 grep | ☐ |
| Healthy-log property over every demo-written log, killed runs included | existing property suites | ☐ |
| M7 eyeball item closed | Phase 0, owner | ☐ |
| Rev 11 carried into code (per-batch sweep + the two new greps) | Phase 4 sweep log | ☐ |

---

## 9. Decision log

| # | Decision | Status |
|---|---|---|
| D50 | **The abandoned-generation remedy**: the store clears `shownPartials` and publishes `.changed` on any throw out of `drive` (D39's "live set moved" half, previously unimplemented); the projection's prune keeps an entry iff classified `.interrupted` **and** present in the store's live set. Shown text visibly shrinks to the durable prefix — owned, and stated in rev 11 item 1 | **Proposed** 2026-08-16 (audit F1); Phase 1 confirms |
| D51 | Demo architecture: one app model owns the store + the single provider-naming `driver()` line; screens own their projections; `isDeleted` drives navigation | **Proposed** 2026-08-16 |
| D52 | Database at `Application Support/LedgerKit/demo.sqlite`; the library's protection floor is the demo's whole answer | **Proposed** 2026-08-16 |
| D53 | DoD-2's provider is PCC, **pending the Phase 1 spike**; on a negative result the fallback (Claude-package ring check, or restate DoD-2) is Alexander's call on the evidence | **Open** — spike scheduled Phase 1 |
| D54 | 4096 budget: short turns for the GIF; `.reduceContext` bubble kept; no compaction wiring — hitting the window renders the bubble, which is correct | **Accepted** 2026-08-16 (owner) |
| D55 | The throw channel is rendered, not swallowed: alert for `persistenceFailure`, prevented-state for `generationInFlight`, ignore `CancellationError`, render-if-ever-reached for the target errors | **Accepted** 2026-08-16 (owner) |

Owner-agreed procedure (not a numbered decision): **Beta 4 is deleted once
Beta 5 is green** — one toolchain, no CI-selection ambiguity (audit F3).

## 10. Status log

| Date | Phase | Tests | Note |
|---|---|---|---|
| 2026-08-16 | **Plan drafted** at the M7 boundary | 452 (429 + 23) | Drafted from the M7 boundary audit (same date). Phase 0 carries Beta 5 + the M7 eyeball item; Phase 1 carries audit findings F1 (D50), F2, F4 and the PCC spike (D53); rev 11 inventory seeded with one item already decided (cut line 1 retired, owner 2026-08-16). Owner sign-offs recorded: Beta 4 deletion post-verification, cut line 1 retirement, PCC spike, eyeball → Phase 0, short-turns budget posture (D54), throw-channel rendering (D55) |
