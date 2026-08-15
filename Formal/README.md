# Formal models

TLA+/PlusCal models of the parts of LedgerKit where correctness is a property of
*interleavings* rather than of a function's output. The pure reducer is
deliberately **not** modelled — it has no concurrency, and `LedgerKitTests`
already sweeps it exhaustively over both hand-written and generated logs, which
is stronger evidence than a model can give because it runs the real code.

Everything here is about `ConversationStore`.

---

## Why this exists

Two consecutive milestone boundary audits found an interleaving bug in the same
verb:

- **M5 audit** — `deleteConversation` waited out a `.running` slot but not a
  `.reserved` one, so a delete could race a start that had claimed its slot and
  not yet appended.
- **M6 audit (A3)** — `deleteConversation`'s cancel-and-wait is not atomic with
  its `DELETE`; a *new* starter interleaving at delete's awaits appends into an
  erased conversation, and `MAX(sequence)+1` restarts at 1, leaving
  genesis-less rows.

One bug per audit, same verb, same class. That cadence is the argument for a
model checker: a human audit finds one interleaving per sitting, and TLC either
finds all of them or reports that there are none.

## The calibration rule

**A model is not trustworthy because it was written carefully.** Before this
model was allowed to say anything new, it had to reproduce a bug already known
to be real:

```
Fix = "none"   →   TLC MUST FAIL with NoOrphanRows violated.
```

It does, in a ten-state trace, in under a second. Only after that does a *pass*
on any other variant carry information. A model too weak to express A3 would
pass everything, and would look exactly like success.

The same discipline applies in the other direction, via `SanityAppendsHappen` —
an invariant deliberately written to be false. A variant can "pass" by being
inert: guard the append hard enough and no rows are written, satisfying every
safety property while modelling a store that does nothing. TLC must report
`SanityAppendsHappen` **violated** for every variant, including the ones that
otherwise pass. It does, for all four.

## Results

| `Fix` | What it models | Result | States |
|---|---|---|---|
| `none` | The store as shipped | **FAILS** — `NoOrphanRows` (this is A3) | 377 |
| `tombstone` | M7 Phase 0's proposed fix | **FAILS** — `NoOrphanRows` | 586 |
| `sticky` | Tombstone that is never cleared | passes (state space exhausted) | 954 |
| `guard` | `append` refuses a non-genesis first row | passes (state space exhausted) | 1044 |

The failing rows stop early on the violation; the passing rows exhaust the
complete state graph (`0 states left on queue`).

### The finding: the proposed tombstone is not sufficient

M7 Phase 0 specifies a `deleting: Set<ConversationID>` set synchronously at
`deleteConversation`'s entry, checked by `reserve`, and **cleared on completion
and on failure**. That clearing is the problem.

The tombstone covers the interval *[delete entry, delete completion]*. The
interval needing cover is *[starter's existence read, starter's append]*. A
starter that read `convExists` before the delete began, and reaches `reserve`
after the delete finished and cleared the flag, meets no guard at all: its
existence read says the conversation exists, the tombstone says no deletion is
in progress, and both are true statements about moments that never overlapped.

Two facts carry the damage past every in-memory check, both verified in the
source rather than assumed:

- `events` has **no foreign key** to `conversations`.
- `append` validates only that each record's own `conversationID` matches its
  target — never that the conversation exists or has a genesis.

**Reachability, honestly.** The trace needs the starter's `existingFold` to
suspend (a cold fold cache) and its continuation to be scheduled after the
deleter has run to completion. Swift actors give no FIFO guarantee across
continuations resumed from different sources — a GRDB callback versus an actor
hop — so this is *permitted* rather than forced. That is the complaint rather
than a weakening of it: under the tombstone, the invariant holds only when the
scheduler cooperates, and nothing in the code requires it to.

Both `sticky` and `guard` close it. `guard` is the more interesting of the two:
it defends at the write transaction, which is the one place where "does this
conversation have rows" and "am I adding rows" are answered together under
SQLite's write lock, so it does not depend on any interleaving. `sticky` costs
an unbounded set of poisoned identifiers for the process's lifetime.

Neither is adopted here. This directory reports; `Documentation/M7-PLAN.md`
decides.

## Running it

Requires a JDK and `tla2tools.jar` (from
[github.com/tlaplus/tlaplus](https://github.com/tlaplus/tlaplus/releases)); the
commands below assume `~/.tla/tla2tools.jar`.

Translate PlusCal → TLA+ after **any** edit to the `--algorithm` block. TLC runs
the translation, not your PlusCal, so skipping this silently checks the previous
version:

```bash
java -cp ~/.tla/tla2tools.jar pcal.trans Formal/LedgerStore.tla
```

Then check one variant:

```bash
java -cp ~/.tla/tla2tools.jar tlc2.TLC -config LedgerStore_none.cfg LedgerStore.tla
```

All four, from inside `Formal/`:

```bash
for v in none tombstone sticky guard; do printf "%-11s " "$v"; java -cp ~/.tla/tla2tools.jar tlc2.TLC -config LedgerStore_$v.cfg LedgerStore.tla 2>&1 | grep -E "is violated|No error has been found" | head -1; done
```

`none` and `tombstone` are **expected to fail**. A run where all four pass means
the model has stopped reproducing A3 and should be distrusted until it does
again.

## Reading the model

One rule carries the whole encoding: **a PlusCal label is an `await`.** A Swift
actor runs one task at a time but yields at every suspension point, so the code
between two awaits is an atomic region and the awaits are where another task may
interleave. PlusCal's semantics are exactly that. Placing labels at Swift's
suspension points is therefore transcription rather than interpretation, which
is what makes this subject worth model-checking and the reducer not.

Two consequences worth internalising before editing:

- **Never add a label to make the translator happy.** PlusCal demands one after
  any statement following an `if` that contains a `goto`. Complying inside what
  should be a single atomic region models a race the code does not have.
  Restructure the condition instead — `SReserve` is written as one guarded
  claim for exactly this reason.
- **Read freshness is load-bearing.** `sawConv` exists to preserve the fact that
  `existingFold`'s answer is stale by the time `reserve` acts on it. Delete the
  local and the bug vanishes from the model while remaining in the code.

The head of `LedgerStore.tla` lists what is abstracted away — one conversation,
no fold cache, no snapshots, no driver, no persistence failures. Those bound
what a pass is allowed to mean.
