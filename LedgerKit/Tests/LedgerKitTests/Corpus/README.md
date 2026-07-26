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

### The reserved `raw` row

```json
{ "sequence": 12, "raw": "…" }
```

Reserved for **M4**, and deliberately unreadable until then: the loader throws
rather than guessing. Synthesising `LoadedEvent.undecodable` test-side would
freeze fixtures against a reimplementation of the two-stage decode boundary,
which is the drift ADR-003 rule 2 exists to prevent.

This is why `rich` and `hostile` have no on-disk form yet — each contains
undecodable rows, which are *loader outcomes* rather than wire bytes. Their
coverage is in-memory, where it is unaffected.

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
   in-memory sweep (truncation, interior-gap, compound, P3).
2. Re-record. If it contains undecodable rows it is skipped on disk until M4.
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
