# The on-disk fixture corpus

Logs as wire bytes, plus the state each one reduces to. Its job is narrow and
long-lived: **prove that a log written by an older LedgerKit still decodes and
still means the same thing.** SPEC §10.2 calls for it; ADR-001 names it as the
evolution safety net that makes the permanent `Payload` encoding survivable.

Run by `CorpusFileTests`. Regenerate with:

```bash
LEDGERKIT_RECORD=1 swift test --package-path LedgerKit
```

## Three directories, three contracts

| Directory | Written by | A diff means |
|---|---|---|
| `dev/` | record mode, from `Corpus.all` | the encoder or the reducer changed — review, then re-record |
| `wire/` | **a human, once** | someone edited a hand-authored file; only the `.txt` may be re-recorded |
| `frozen/` | the release that created it, then never again | **a regression.** Always. There is no branch in the test that can rewrite these |

`wire/` exists because the corpus must contain bytes *this* version cannot
write — a payload kind from the future, an outcome whose discriminator we have
never heard of, an old field shape. Round-tripping those through our encoder
would silently rewrite them into shapes we already understand, which is the one
thing a forward-compatibility fixture must not do. So they are authored by hand
and the writer never touches them.

Three fixtures live there:

| Fixture | What it proves |
|---|---|
| `tolerantTerminals` | Three §6.6-row-3 shapes — unknown outcome tag, unknown *nested* error tag, absent outcome field — all land as `.failed(.unrecognized(…))` with **zero** diagnostics and a terminal timestamp. The whole tolerant-terminal story, from bytes |
| `undecodableRows` | Rows 1 and 2 from bytes: a truncated row and a wrong-typed envelope field lose identity; a future payload kind keeps it and names itself; a non-object payload keeps identity with no legible tag. Reduction continues past all five, and the title proves it |
| `contextSizeExceededLegacy` | That widening an error case's payload was **additive** (M4-PLAN D17). Three turns: one written *before* `contextSizeExceeded` gained `contextSize`/`tokenCount` (the fields decode as nil), one written after, and one written by a *later* version carrying a field this build has never heard of. Zero diagnostics, one affordance — a widened case is not a new kind, and an unknown field is not an unknown tag |

`undecodableRows` also pins one thing it does not endorse: a payload kind this
version **does** know, carrying a body that will not decode, is reported as
`unknownPayloadKind("deltaAppended")`. The disposition is right — skip the row,
keep the identity, keep reading — but the wording misleads, because §6.6 rows 1–2
have no case for "known kind, malformed body". Pinned so it cannot drift
unnoticed, and flagged for SPEC rev 7 to either widen row 2 or add a row.

## File format

Two files per fixture: `<name>.json` (the log) and `<name>.txt` (the state it
reduces to).

```json
{
  "conversationID": "01980E5A-0000-7000-8000-000000000001",
  "rows": [
    { "sequence": 1, "event": { "id": "…", "conversationID": "…", "timestamp": "…", "payload": { "kind": "conversationCreated" } } }
  ]
}
```

The schema **mirrors the events table** (§9) rather than inventing a container:

- `sequence` sits *outside* the blob, exactly as it does in the real
  `(conversation_id, sequence)` key. A fixture therefore cannot express the
  blob/column disagreement the physical design makes unrepresentable.
- `conversationID` appears both on the document and inside each event, because
  that duplication is precisely what §6.6 row 4 checks — a fixture can contain a
  foreign event, and one does.
- **Gaps need no representation.** A missing sequence number is a missing row.
- `timestamp` is millisecond ISO 8601 and must be *born* canonical, never
  canonicalized at encode (§6.1 R-5). `timestampsAreCanonical` enforces it here
  so M4's store inherits a fixture that already fails if it slips.

### The `raw` row — literal bytes *(implemented at M4 Phase 2)*

```json
{ "sequence": 12, "raw": "{\"id\":\"…\",\"payload\":{\"kind\":\"messagePinned\"}}" }
```

A row stored as bytes rather than as a decoded record, and read by
**`SQLitePersistenceStore.load`** — the very function the store calls on every row
it reads. So a fixture's damaged rows and a real damaged database's produce
identical `LoadedEvent`s, by construction rather than by maintenance.

It was reserved-but-unreadable through M3 for a reason worth remembering: without
a real two-stage loader, the only way to give these rows meaning was to
synthesise `LoadedEvent.undecodable` test-side — which would have frozen fixtures
against a *reimplementation* of the decode boundary, the drift ADR-003 rule 2
forbids. The loader threw rather than guessing.

Consequences now that it works:

- **`rich` and `hostile` are on disk** (M4 Phase 2). Their undecodable rows are
  built from bytes by `Log.unknownPayloadKind(_:)` and `Log.corruptRow(_:)`, so
  the file contains exactly the input the in-memory fixture folded.
- **The corpus now depends on the loader**, which is a coverage *gain*: break the
  loader's tag recovery and these fixtures' residue expectations fail. While they
  synthesized their own reasons, no loader bug could reach them.
- `Log.undecodable(_:identified:)` still exists and still synthesizes. That is
  legitimate for **fold-level** unit tests — the fold's contract is to turn a
  loader outcome into a diagnostic, and where the value came from is none of its
  business — but a synthesized row has no honest on-disk form, so
  `CorpusDocument(_:)` refuses to serialize one.

Bytes need not be undecodable; that is merely what they are used for. A row whose
bytes decode cleanly belongs in `event`, which is the diffable form.

## What `.txt` contains, and what it deliberately does not

The dump renders **`FoldedState`, not `Conversation`.** The folded layer is
everything the *log* determines; classification additionally takes a
`RecoverabilityMapping`, and §8 explicitly wants mapping fixes to land and
retroactively upgrade affordances on historical failures. Freezing classified
state would make every legitimate §8 improvement break every frozen fixture —
pressure to "fix" the corpus, which is how a frozen corpus stops meaning
anything. Folded state is what I1's first half promises is stable forever, so it
is what this format commits to.

Nothing in the dump renders via `description` or `String(describing:)`. ADR-001
declares diagnostic prose non-contractual and free to reword, and reflection
output is a compiler implementation detail. Every rendering is an explicit
exhaustive switch over **case names**, which are the contract — and which a
compiler error forces someone to confront when the inventory grows.

## Adding a fixture

1. Add it to `Corpus.all` in `Corpus.swift`. It immediately inherits every
   in-memory sweep (truncation, interior-gap, compound, P3) — and, if it is
   gapless, single-stream and free of byte-built rows, the store round-trip
   equivalence sweep too (`isStoreReplayable` states that condition).
2. Re-record. Damaged rows want `unknownPayloadKind(_:)` / `corruptRow(_:)`, which
   go through the real loader and therefore serialize; `undecodable(_:)`
   synthesizes and will refuse to.
3. Commit both files. Review the `.txt` as carefully as the code — it is the
   assertion.

## Freezing a release (M9)

At each tagged release, `dev/` is copied into `frozen/<version>/` and never
touched again:

```bash
git switch --detach v0.1.0
LEDGERKIT_RECORD=1 swift test --package-path LedgerKit   # confirm dev/ is clean at the tag
cp -R Tests/LedgerKitTests/Corpus/dev Tests/LedgerKitTests/Corpus/frozen/0.1.0
```

Then commit on the next development branch. From that moment the rule is
absolute: **a change under `frozen/` is a regression, not a fixture that needs
updating.** If a future decoder genuinely cannot read a frozen log, the answer
is an upcaster (ADR-001's named evolution idiom) — a decode-time old-shape →
current-shape transform, so the reducer stays single-shape and the frozen bytes
stay untouched.
