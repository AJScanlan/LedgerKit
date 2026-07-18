# ADR-001 — Tagged-JSON event encoding & the discriminator registry

**Status:** Draft · opened 2026-07-18 at M1 · ratifies at M9
**Spec:** §6.1 (envelope/payload, tolerant terminals, gaps), §6.6 (quarantine table), §9
(persistence & versioning), §10 (test corpus), §13 DoD-5
**Code:** not yet written — `Core/` payload types land later in M1

> **Scope note.** §6.6 says its table "is owned by ADR-001." This ADR owns the *decision
> and reasoning*; the normative twelve rows stay in §6.6 as the single copy. Reproducing
> them here would guarantee drift. See `README.md`.

## Context

`Payload` is a ten-case enum whose encoded form is read by every future version of
LedgerKit, forever. §9 names its `Codable` evolution "the sharpest long-term maintenance
edge in the whole design." Logs persist across app versions, so a v0.1 reader will meet
events written by v0.4, and a v0.4 reader will meet v0.1 logs that can never be rewritten
— the log is append-only truth.

## Settled by the spec

Recorded here for completeness; the spec holds the normative text.

| Decision | Where |
|---|---|
| Encoding is **tagged JSON** (ratified; was OQ1) | §9 |
| Every event row carries a schema version; readers read all past versions, write current | §9 |
| Discriminator registry: tags are **never reused**; removed tags stay **reserved forever** | §9, §13 DoD-5 |
| Unknown payload discriminator → quarantine, conversation loads degraded | §6.6 row 2 |
| **Tolerant-terminal exception:** a `generationEnded` with an unknown nested outcome does *not* quarantine — it lands as `.failed(.unrecognized(…))` | §6.1, §6.6 row 3 |
| Gap-diagnostic rule: one diagnostic per *contiguous* gap, not per missing row | §6.1 |
| Version-frozen fixture corpus in CI forever | §10 |
| **Upcasters** (decode-time old-shape → current-shape) are the named evolution idiom, so the reducer stays single-shape | §10 |
| `sequence` lives only in the events-table key — the blob omits it | §6.1, §9 |
| `conversationID` is duplicated (column *and* blob) on purpose; disagreement quarantines | §6.1, §6.6 row 4 |

The tolerant-terminal rule is the single deliberate asymmetry in decode strictness, and it
exists because terminals are the only events whose *absence* carries meaning (I5). Without
it, quarantining an unfamiliar outcome would manufacture a forged `.interrupted` — a
v0.2 log's new error case would re-render historical *failures* as *crashes* on v0.1
readers.

## Open — to decide before M9

### OQ-1. Named keys, not positional encoding *(proposed: named)*

Three payload cases pair two values of the **same** type:

```swift
case userMessageAppended(MessageID, content: String, parent: MessageID?)
case generationStarted(GenerationID, MessageID, parent: MessageID?, model: ModelDescriptor)
case messageEdited(original: MessageID, replacement: MessageID, content: String)
```

Positional encoding makes a transposition a silent, well-formed decode into the wrong
identity — surfacing far downstream as §6.6 row 8/9/11 residue rather than as a decode
error. Named keys make it a key mismatch, and make hostile fixtures self-documenting.

This also subsumes the wire-interchangeability cost accepted in ADR-002 §4: all four
identifiers encode to indistinguishable bare strings, so *no* identifier-level typing can
protect same-typed pairs. Named keys protect all of them at zero wire cost.

**Cost:** larger blobs than a positional array. Judged worth it — these are chat logs, and
SQLite compresses poorly-entropic key repetition well enough.

### OQ-2. The frozen corpus asserts **encoded bytes**, not decode equality *(proposed)*

Round-trip tests catch an *asymmetric* encoder/decoder bug. They cannot catch a
*symmetric* one: if encoder and decoder are consistently transposed, round-trip passes
while the on-disk format is silently wrong — and that format is then permanent. Only a
fixture asserting literal encoded bytes catches it.

M1's exit criterion ("every type round-trips through `Codable`") is therefore necessary
but not sufficient; §10's version-frozen corpus is what closes the gap, and it must
compare bytes.

### OQ-3. The registry's actual tag strings

Blocked on the `Payload` enum landing. Open sub-questions: do tags mirror Swift case names
(`"generationStarted"`) or get stable short codes (`"gen_start"`)? Case names are
readable in fixtures and diffs; short codes decouple the wire from Swift renames. Given
tags can never be reused, a rename would otherwise burn a tag permanently.

### OQ-4. Where the schema version physically lives

§9 says every row carries one. Column, envelope field, or both? Interacts with the
`sequence`/`conversationID` split above — one is key-only, the other deliberately
duplicated, so there is precedent in both directions.

### OQ-5. Registry enforcement

Is "tags are never reused" a convention, a test over a checked-in manifest, or a compile
-time construct? A test reading a frozen `tags.json` is the cheap version and would fail
loudly on an accidental reuse.

## Consequences

- Every new payload kind is a permanent registry entry (§6.1: "ten payload kinds; resist
  adding more").
- Forward compatibility degrades rather than fails: unfamiliar events quarantine, the
  conversation still loads, and unfamiliar *outcomes* become generic failures.
- The version-frozen corpus is load-bearing infrastructure, not a nicety — it is the only
  instrument that detects a symmetric encoding error.
