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
| `GenerationError.kind` | `modelUnavailable` `contextSizeExceeded` `guardrailViolation` `refusal` `unsupported` `rateLimited` `providerFailure` `transport` `unrecognized` |
| `ModelUnavailability` (raw string) | `deviceNotEligible` `appleIntelligenceNotEnabled` `modelNotReady` |
| `UnsupportedFeature` (raw string) | `capability` `transcriptContent` `generationGuide` `languageOrLocale` |
| `TransportFailure` (raw string) | `timeout` `connectivity` `tls` |
| `ToolRecord.Status` (raw string) | `succeeded` `failed` |

**Reserved — removed tags, never reusable (opened by SPEC rev 6):**

| Level | Tag | Removed | Why |
|---|---|---|---|
| `GenerationError.kind` | `contextWindowExceeded` | SPEC rev 6, M3 | Renamed to `contextSizeExceeded` to mirror Apple's `LanguageModelError` case name exactly (SPEC §8). No released version ever wrote it — v0.1 is untagged and the frozen corpus is empty — so **no upcaster is required**. It is reserved anyway: the registry rule is that a tag which has *ever* named something may never name anything else, and the cheapest moment to honour that is the one where it costs nothing. |

The reserved list is the mechanism that makes R-2's "tags are never reused" auditable
rather than aspirational. A tag arrives here the moment it stops being current, with the
revision that retired it and whether an upcaster exists; a reader deciding what a
strange tag in an old log means should never have to reconstruct that from git history.

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

### R-5. Timestamps are canonicalized at **birth**, not at encode *(ratified 2026-07-25, M1 audit)*

R-4 pins the wire form at millisecond precision, but `Date` is a `Double` of seconds and
`Date()` carries more. So the encoding is **lossy for values minted from the system clock** —
measured, not assumed:

```
raw    1784979047.371011
wire   "2026-07-25T11:30:47.371Z"
back   1784979047.371          →  equal: false, delta 1.1e-05
```

`LedgerEvent.Record` is `Equatable`, and P1/P3 (§10.6) compare an in-memory tail or fold against
a re-decoded log. An unrounded stamp therefore makes the two most load-bearing property tests in
the package fail on ~10 µs of clock jitter — or, far worse, pressures them into an
approximate-equality helper, which would mask exactly the class of bug P3 exists to catch.

**Decision: the store truncates to wire precision when it stamps.** Every `Record` is born at
millisecond precision, so `decode ∘ encode` is the identity for timestamps and equality is exact
at every layer above.

**Rejected: canonicalize inside `encode(to:)`.** It looks equivalent and is not — it gives every
event two identities depending on whether it has yet been to disk, so `Record`'s `Equatable`
conformance would quietly disagree with its own persistence. Canonicalization belongs at the one
moment a timestamp enters the system, which is also the only moment it is ambiguous.

**Implementation: round-to-nearest on the integer millisecond count.**

```swift
let milliseconds = (stamp.timeIntervalSince1970 * 1000).rounded()
return Date(timeIntervalSince1970: milliseconds / 1000)
```

This lands on the `Double` nearest `ms/1000`, which is exactly the value parsing that millisecond
string returns — so the round-trip closes.

**Rejected, and worth recording because it is the tempting answer:** defining canonical as
`parse(format(x))` — "whatever reading my own output yields" — which *appears* idempotent by
construction. It is not. The formatter emits a decimal whose nearest `Double` sits slightly
**below** it about half the time, so re-formatting sheds another millisecond, and roughly half of
all inputs never reach a fixed point. Measured: 99,776 of 200,000 random dates were
non-idempotent. This was implemented, shipped into the working tree, and caught by the sweep test
below — which is the argument for the sweep. A single hand-picked fixture passed.

**⚠️ Load-bearing dependency: `ISO8601DateFormatter` rounds; `Date.ISO8601FormatStyle`
truncates.** The modern format style is a `Sendable` value type and therefore the more natural
choice under strict concurrency — and substituting it moves ~74% of timestamps one millisecond
earlier (74,349 of 100,000 measured) *and* breaks `canonical(_:)`, whose stability assumes
rounding. That is precisely the silent format drift R-4 exists to prevent, so the two APIs are not
interchangeable here. `WireFormatTests` pins the behaviour with a value whose nearest `Double`
falls low (`…011.652` must encode `.652Z`, not `.651Z`), which fails loudly if anyone swaps them.

**Cost of keeping the reference-type formatter:** it must be cached, which costs a
`nonisolated(unsafe)` static. Constructing an `ISO8601DateFormatter` measures ~120 µs, so a
10k-event cold open (§9) would otherwise spend ~1.2 s allocating formatters it immediately
discards — 75× the cached cost. The opt-out is narrow and defensible: both instances are
configured once and never mutated, Foundation's date formatters are documented thread-safe for
formatting and parsing, and this is a private cache inside an internal helper rather than a
`Sendable` conformance on public API, which is what tenet 6 actually prohibits.

**Scope.** Timestamps are the only field minted from a high-precision ambient clock, so they are
the only field needing this. Durations truncate too (R-4), but they arrive from §8's normalization
already coarse — a `Retry-After` is whole seconds, a tool duration is measured in ms — so there is
no jitter to canonicalize.

**Tested** in `WireFormatTests` ("Timestamp canonicalization"), over a 2,000-date sweep rather
than a fixture, in both directions: canonical stamps round-trip equal and are idempotent; a raw
sub-millisecond `Date` provably does not round-trip, which is why the rule exists. The store's
stamping site lands at M5.

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

Related: the sentinel strings involved (`"undecodable outcome: "` for an unreadable `Outcome`,
`"undecodable error: "` for a readable `Outcome` whose nested `GenerationError` was not,
`"<missing>"`, `"<unreadable>"`, and §8's `"driver:"` prefix) are **diagnostic, non-contractual** —
matching on them outside log triage is unsupported, and they may change wording without
notice. Declared here so Hyrum's Law doesn't ossify them by usage.

## Open — to decide before M9

*(Renumbered from the draft's OQ-1…5 to avoid colliding with the spec's beta-tracking
OQ1–9, §14.)*

### ~~D-1. The frozen corpus asserts **encoded bytes** under a **canonical encoder**~~ — **closed at M4 Phase 1**

Round-trip tests catch an *asymmetric* encoder/decoder bug. They cannot catch a
*symmetric* one: if encoder and decoder are consistently transposed, round-trip passes
while the on-disk format is silently wrong — and that format is then permanent. Only a
fixture asserting literal encoded bytes catches it.

**Resolved (2026-07-26):** the canonical configuration is `WireJSON`
(`Core/WireCoding.swift`) — `[.sortedKeys, .withoutEscapingSlashes]`, compact — and the
store encodes through nothing else. `sortedKeys` is not aesthetics; it is the
*precondition* for deterministic bytes, without which the frozen corpus cannot mean
anything. `withoutEscapingSlashes` because `\/` is legal JSON that no reader needs and
every human reading a fixture trips over.

One nuance the original phrasing glossed: the store and the corpus share the
**configuration**, not the whitespace. Corpus *files* pretty-print — readability is their
job, and whitespace is invisible to the value comparisons those tests actually make.
Byte-level pinning therefore happens against `WireJSON` output, which is what
`WireFormatTests`' exact-string assertion now uses.

**Factories, not shared instances**, and the contrast with R-5 is the point: `WireDate`
caches because an `ISO8601DateFormatter` measured ~120 µs to build and a 10k-event cold
open would have spent ~1.2 s on it. A `JSONEncoder` has no formatter to construct, so one
per call-site — a local, never shared across isolation domains — buys safety (no
`nonisolated(unsafe)`, no assumption about Foundation's thread-safety) for no measured
cost. Reach for a cache here only with a measurement in hand.

### ~~D-2. Where the schema version physically lives~~ — **closed at M4 Phase 1: column-only**

§9 says every row carries one. Column, envelope field, or both? Interacts with the
`sequence`/`conversationID` split — one is key-only, the other deliberately duplicated,
so there was precedent in both directions.

**Resolved (2026-07-26): the column only** — `events.schema_version`, alongside
`sequence`. A version is *loader routing metadata*, which is what the key columns are for,
and "bytes below, meaning above" puts bookkeeping in columns. The counterargument — that a
self-describing blob survives being separated from its row — does not survive contact with
how logs actually move: transport carries **rows** (sequence, version, blob), never bare
blobs, a rule this ADR already imposes in the lossy-decode section. Duplicating the
version would have added a permanent envelope key to every event ever written to buy
self-description nothing needs.

Consequence recorded so the column's silence is not mistaken for neglect: **nothing reads
it yet, by design.** With one version there is nothing to route. It is the hook an
*upcaster* hangs from, and the first version bump adds the switch. `LedgerSchema`
(`Store/LedgerSchema.swift`) holds it, deliberately separate from the snapshot
`reducerVersion` because the two fail in opposite directions — a payload bump selects an
upcaster and invalidates nothing, a reducer bump discards snapshots and migrates nothing. A
single "schema version" could only have had one of those behaviours.

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
