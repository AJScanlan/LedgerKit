# Enhancements backlog

Improvements identified at the M4 boundary audit (2026-07-26) and deliberately
deferred — none blocks M5. Each entry records enough context to be picked up
cold. Distinct from the ROADMAP (milestone work the spec requires) and from
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
