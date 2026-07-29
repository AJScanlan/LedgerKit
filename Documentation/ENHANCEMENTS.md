# Enhancements backlog

Improvements identified at milestone boundary audits (entries 1–2: M4,
2026-07-26; entry 3: M5, 2026-07-28) and deliberately deferred — none blocks
the next milestone. Each entry records enough context to be picked up cold.
Distinct from the ROADMAP (milestone work the spec requires) and from
SPEC §12 (versioned scope): these are library-quality items that can land
whenever they earn their slot.

---

## 1. `MessageTree` whole-tree access

**Status:** deferred at the M4 audit · **Natural slot:** with v0.2's export work, or earlier if a consumer asks

`MessageTree` exposes `subscript(id:)`, `children(of:)`, `siblings(of:)`, and
`rootChildren` — reachable traversal only. There is no `count`, no `isEmpty`,
and no way to enumerate every message without hand-rolling a walk from
`rootChildren`.

Two reasons this is worth closing:

- **Consumers will write the traversal recursively.** The library's own code
  deliberately avoids recursion over tree depth because depth tracks message
  count in a linear conversation (`Folder.reconstructRouting` is an iterative
  worklist for exactly this reason, per I2's no-trap-no-hang promise) — but
  nothing stops an app from writing the naive recursive version against a long
  conversation. Shipping the safe iterative traversal removes the only reason a
  consumer would ever write tree-walking code the library hasn't audited.
- **Export needs it anyway.** v0.2's Markdown/JSON export (SPEC §12) has to
  enumerate every node, reachable or not. Search and stats surfaces want the
  same thing.

Sketch: `var count: Int`, `var isEmpty: Bool`, and a deterministic `Sequence`
view (depth-first, sibling order — the same order `reconstructRouting` walks,
so iteration order is documented and hasher-independent, preserving the I1
discipline that dictionary order never reaches output). Decide at design time
whether unreachable orphans (kept deliberately by `classify` — silently losing
messages is worse than keeping an orphan) appear in the sequence; whichever way
it goes, say so in the doc comment.

## 2. DocC catalog

**Status:** deferred at the M4 audit · **Natural slot:** M9, alongside the README

The doc comments across both packages are already launch-post quality; a DocC
catalog is mostly assembly, not writing. Worth including:

- **A "recovery story" article** — §6.3's three-name table
  (`.open` → `.interrupted` → `.streaming`) narrated right-to-left, which is
  the crash-recovery pitch in one page.
- **The "why not just persist `session.transcript`?" article** — DoD-4's
  incumbent argument (SPEC §2), shared with the README.
- **The exhaustive-`switch` showpiece** (§11) as a tutorial-style page.
- **`Understudy` gets its own catalog** — it is the gateway-drug product and is
  useful to any Foundation Models app; its docs should not assume LedgerKit.

No code changes required; the `///` comments are DocC-ready. Budget one pass
for `- Parameters:`/`- Returns:` formalization on the public surface.

## 3. Third-party `GenerationDriving` testability

**Status:** deferred at the M5 boundary audit (priced earlier at M5 Phase 0,
gate item 2) · **Natural slot:** v0.2, with the driver-ecosystem story

SPEC §7.9 says *"anything else that ever runs inference for LedgerKit writes
another"* conformance — the seam is explicitly designed for drivers beyond the
one M6 ships. But `GenerationRequest` and `GenerationChannel` construction is
internal (deliberately, per M4 Phase 0's derived-state rule: a request
describes a reduction that happened, and only the store performs reductions).
Consequence: an out-of-package driver author can *conform* to
`GenerationDriving` and never *invoke* their own `generate` — they cannot
build a request to hand it, nor a channel to catch its signals.

Fine for v0.1: the only conformances are in-package (M6's `GenerationDriver`,
the test target's `ScriptedDriver`), and M5 recorded this as "the one place M5
narrows what v0.2 might want." Reopening is additive. Candidate shapes, to be
priced when a real third-party driver exists to price against:

- A test-support factory (`GenerationRequest.fixture(...)` behind a
  test-support product, or an `Understudy`-style companion) that builds
  requests by reducing a short log — which exercises the real semantics, the
  same argument `Message`'s internal init makes.
- Publishing `GenerationChannel.makeStream()` alongside it, since a request
  without a channel still cannot call `generate`.

Whichever shape wins, the derived-state rule should survive it: a request
should still *come from* a reduction, not from a memberwise init.
