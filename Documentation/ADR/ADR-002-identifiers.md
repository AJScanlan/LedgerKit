# ADR-002 — Identifier design

**Status:** Accepted · 2026-07-18 · implemented at M1
**Spec:** §6.1 (event envelope, ordering), §6.2 (derived state), I7 (identity)
**Code:** `Core/Identifiers.swift`, `Core/IDGenerator.swift`, `Core/UUIDv7.swift`

## Context

The ledger names four things: events, conversations, messages, and generations. These
identifiers are on the wire, so their shape is API forever (§6.1) — and they are minted
inside the store's append transaction, which means anything ambient they read becomes
something fixtures cannot reproduce.

Foundation mints only UUIDv4, and §6.1 calls for UUIDv7 on `EventID`.

## Decisions

### 1. Four distinct types, not a shared `UUID` alias

I7 binds `GenerationID ↔ MessageID` 1:1 in v0.1, so call sites routinely hold both,
carrying *different* values that are never equal. A shared alias would let them be
swapped silently; the mistake would surface far downstream as §6.6 row 8/9 quarantine
residue rather than as a build failure.

A `LedgerIdentifier` protocol carries the shared conformances. It is closed by
convention — an extension point is not wanted here.

### 2. UUIDv7 for all four

§6.1 mandates v7 only for `EventID` (time-sortable identity for debugging, SQLite index
locality, future log-shipping). We extend it to all four for **uniformity**: one minting
path, one set of tests, and a rule the next person adding an identifier can apply without
re-litigating. Every identifier in a log dump is then self-dating, which is worth more
than the marginal privacy of the three that did not strictly need it.

**Cost, accepted:** every identifier now discloses its creation time to the millisecond.
`ConversationID` is the exposed one — it is most likely to appear in a URL, an export, or
a share sheet, where it tells a recipient when the conversation began. Revisit if
conversation IDs ever become externally shareable artifacts.

### 3. Deliberately **not** `Comparable`

§6.1 makes `sequence` the sole authoritative order, and I1 forbids wall-clock in the
reducer. Because v7 sorts chronologically, a `Comparable` conformance would make
`events.sorted()` compile and quietly produce timestamp order — an I1 violation that
type-checks. Omitting the conformance turns it into a compile error.

This is the tenet-1 argument ("illegal states unrepresentable") applied to the *absence*
of an API: the conformance is missing on purpose, and that is load-bearing.

### 4. Encoded as a bare UUID string

`{"id":"019F…"}`, not `{"id":{"uuid":"019F…"}}`. Keeps hostile fixtures (§10)
hand-writable and stores cleanly in SQLite.

Spelled out explicitly rather than inherited from `RawRepresentable`'s stdlib `Codable`
conformance: §9 calls encoding evolution the sharpest maintenance edge in the design, and
an inherited conformance would define the wire format in the standard library rather than
in this repo, where a toolchain upgrade could shift it.

**Cost, accepted:** all four encode identically, so the wire cannot distinguish them.
Considered and rejected: type-prefixed strings (`"msg_019F…"`). It would guard the
`MessageID`/`GenerationID` swap — the one case the type system already guards — while
doing nothing for `original`/`replacement` or message/`parent`, which are same-typed pairs
in three payload cases. Named keys in the tagged-JSON encoding cover all of them at no
wire cost; see ADR-001.

### 5. No ambient minting

There is no `MessageID()`. Identifiers come only from an `IDGenerator`, which takes its
randomness and its clock as injected dependencies. A seeded generator produces
byte-identical identifiers on every run, which is what makes the M3 golden-log corpus
(§10.2) snapshot-testable at all.

**Cost, accepted:** the store must thread a generator to every mint site. This is the
same discipline §6.3 imposes on the reducer (no clocks, no I/O), applied one layer down —
and it is what let the v7 generator have a clock-regression test at all.

## Consequences

- Identifier type errors are caught at compile time; identifier *value* errors are caught
  at reduce time as §6.6 quarantine.
- `IDGenerator` is generic over its RNG, so the generic parameter propagates to anything
  storing one. If that becomes noisy in `Store/`, an existential or a `Dependencies`-style
  injection is the escape hatch — not an ambient initializer.
- The 12-bit `rand_a` counter caps minting at 4096 identifiers per millisecond before the
  generator borrows from the next millisecond. Monotonicity holds regardless.
