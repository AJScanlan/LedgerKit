# ADR-001 — Tagged-JSON event encoding & the discriminator registry

**Status:** Draft · opened 2026-07-18 at M1 · updated 2026-07-19 (M1 wire types landed) · ratifies at M9
**Spec:** §6.1 (envelope/payload, tolerant terminals, gaps), §6.6 (quarantine table), §9
(persistence & versioning), §10 (test corpus), §13 DoD-5
**Code:** `Core/LedgerEvent.swift`, `Core/Outcome.swift`, `Core/GenerationError.swift`,
`Core/ToolRecord.swift`, `Core/WireCoding.swift` · pinned by
`Tests/LedgerKitTests/WireFormatTests.swift`

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

## Ratified at M1 (2026-07-19) — decisions now in code

### R-1. Flat tagged objects; `kind` is a reserved key

The discriminator is a `"kind"` field **beside** the payload fields, at every tagged level
(`Payload`, `Outcome`, `GenerationError`):

```json
{"kind":"generationEnded","generationID":"…","outcome":{"kind":"failed","error":{"kind":"rateLimited","retryAfter":30000}}}
```

Chosen over single-key nesting (`{"generationEnded":{…}}`) and a `kind`+`data` wrapper.
Rationale: fixtures double as living documentation (§10.2), and the flat form reads best;
discriminator extraction for quarantine diagnostics and the tolerant-terminal probe is a
trivial keyed read. **Registry rule this creates: no payload field may ever be named
`kind`.** The closed event set makes this easy to police; the registry check (D-3) should
enforce it.

### R-2. Named keys, not positional *(was draft OQ-1 — accepted as proposed)*

Three payload cases pair two values of the **same** type
(`userMessageAppended`, `generationStarted`, `messageEdited`). Positional encoding makes a
transposition a silent, well-formed decode into the wrong identity — surfacing far
downstream as §6.6 row 8/9/11 residue rather than as a decode error. Named keys make it a
key mismatch, and make hostile fixtures self-documenting.

This also subsumes the wire-interchangeability cost accepted in ADR-002 §4: all four
identifiers encode to indistinguishable bare strings, so *no* identifier-level typing can
protect same-typed pairs. Named keys protect all of them at zero wire cost.

**Consequence:** the field keys are wire contract alongside the tags — `messageID`,
`parent`, `original`, `replacement`, etc. are as permanent as the kinds themselves.

**Cost:** larger blobs than a positional array. Judged worth it — these are chat logs, and
SQLite compresses poorly-entropic key repetition well enough.

### R-3. Tags mirror Swift case names; the `Kind` enums are the registry's code form *(was draft OQ-3)*

Case-name tags (`"generationStarted"`, not `"gen_start"`) — readable in fixtures and
diffs. The draft's rename concern (a Swift rename burning a tag forever) is mitigated by
the implementation shape: each codec declares a private `Kind: String` enum whose **raw
values are the wire**; a future Swift case rename keeps the old raw value and burns
nothing.

Current registry inventory (frozen; additions append here):

| Level | Tags |
|---|---|
| `Payload.kind` | `conversationCreated` `userMessageAppended` `instructionsChanged` `generationStarted` `deltaAppended` `toolInvocationRecorded` `generationEnded` `messageEdited` `activePathChanged` `titleChanged` |
| `Outcome.kind` | `completed` `failed` `cancelled` |
| `GenerationError.kind` | `modelUnavailable` `contextWindowExceeded` `guardrailViolation` `rateLimited` `providerFailure` `transport` `unrecognized` |
| `ModelUnavailability` (raw string) | `deviceNotEligible` `appleIntelligenceNotEnabled` `modelNotReady` |
| `TransportFailure` (raw string) | `timeout` `connectivity` `tls` |
| `ToolRecord.Status` (raw string) | `succeeded` `failed` |

### R-4. Scalar wire forms are pinned in the types, not encoder configuration

- **Durations** (`ToolRecord.duration`, `rateLimited.retryAfter`): integer
  **milliseconds** (`Int64`). Integer-exact for sub-second tool timings and Retry-After
  delta-seconds alike.
- **Timestamps**: ISO 8601 with fractional seconds (`2026-07-18T09:30:00.000Z`),
  hand-coded in `Record`; decode also accepts the fraction-less form. Millisecond
  precision — ample for a display/audit-only field the reducer never reads.
- **Optionals**: nil = **absent key**, never `null` — the additive-evolution posture;
  asserted by test.
- **Identifiers**: bare UUID strings (ADR-002).

All four are implemented in the types' own `Codable` conformances so that no
`JSONEncoder`/`JSONDecoder` strategy can move the format.

## Consequence discovered at implementation: tolerant decode is **lossy**

Decoding a log written by a future LedgerKit is not injective: an unknown outcome
`{"kind":"resolvedOffline",…}` decodes to
`.failed(.unrecognized(description: "undecodable outcome: resolvedOffline"))`, and
re-encoding that value writes the *degraded* bytes. Decode∘encode is identity;
**encode∘decode is not** — by design, wherever the tolerant-terminal rule fires.

Rule this imposes: **degraded values exist only in memory. Any log transport — export,
log-shipping (v0.3 sync doc), migration tooling — must move original bytes, never
decode-and-re-encode.** Append-only storage makes this moot inside the store today; the
rule exists so no future feature violates it casually. (This is the general
tolerant-reader lesson: bytes are the truth, decoded values are a view.)

Related: the sentinel strings involved (`"undecodable outcome: "`, `"<missing>"`,
`"<unreadable>"`, and §8's `"driver:"` prefix) are **diagnostic, non-contractual** —
matching on them outside log triage is unsupported, and they may change wording without
notice. Declared here so Hyrum's Law doesn't ossify them by usage.

## Open — to decide before M9

*(Renumbered from the draft's OQ-1…5 to avoid colliding with the spec's beta-tracking
OQ1–9, §14.)*

### D-1. The frozen corpus asserts **encoded bytes** under a **canonical encoder** *(was OQ-2)*

Round-trip tests catch an *asymmetric* encoder/decoder bug. They cannot catch a
*symmetric* one: if encoder and decoder are consistently transposed, round-trip passes
while the on-disk format is silently wrong — and that format is then permanent. Only a
fixture asserting literal encoded bytes catches it.

Byte assertion requires deterministic bytes, so this decision now includes its
prerequisite: a **canonical encoder configuration** — `outputFormatting = [.sortedKeys]`
at minimum (decide slash-escaping alongside) — which the M4 store must share, or the
corpus asserts bytes the store doesn't produce. `WireFormatTests` pins one exact JSON
string under sorted keys as the down payment; the version-frozen corpus (§10.2, M3)
generalizes it.

### D-2. Where the schema version physically lives *(was OQ-4)*

§9 says every row carries one. Column, envelope field, or both? Interacts with the
`sequence`/`conversationID` split — one is key-only, the other deliberately duplicated,
so there is precedent in both directions. Decide at M4 with the table schema.

### D-3. Registry enforcement *(was OQ-5)*

Is "tags are never reused" a convention, a test over a checked-in manifest, or a
compile-time construct? A test reading a frozen `tags.json` (mirroring the R-3 inventory,
plus the R-1 reserved-`kind` rule and R-2's field keys) is the cheap version and fails
loudly on accidental reuse. Now that the registry exists in code, this fits naturally into
M3's version-frozen-corpus scaffolding rather than waiting for M9.

## Consequences

- Every new payload kind is a permanent registry entry (§6.1: "ten payload kinds; resist
  adding more") — and so is every field key (R-2) and every tag at every level (R-3).
- Forward compatibility degrades rather than fails: unfamiliar events quarantine, the
  conversation still loads, and unfamiliar *outcomes* become generic failures.
- Tolerated-but-degraded values must never be re-serialized as log data; logs transport
  as bytes.
- The version-frozen corpus is load-bearing infrastructure, not a nicety — it is the only
  instrument that detects a symmetric encoding error.
