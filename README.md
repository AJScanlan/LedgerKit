<!--
  DRAFT — M9 Phase 3. Not yet reviewed cold (see M9-PLAN Phase 3's review gate).

  Two things are deliberately unfinished:
   * GIF slots are marked TODO. dod1.gif and dod2.gif exist in Documentation/assets/.
   * The install line names `from: "0.1.0"`, which is not tagged yet (Phase 4).
     It is written as it will read on the day it ships, not as it resolves today.

  Every code block below is lifted from something that compiles — the source file
  is named in a comment beside each. Keep it that way (Phase 3 checklist).
-->

# LedgerKit

> **The state layer Foundation Models doesn't ship.**

[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2026%2B%20%7C%20macOS%2026%2B-lightgrey.svg)](#requirements)
[![CI](https://github.com/AJScanlan/LedgerKit/actions/workflows/ci.yml/badge.svg)](https://github.com/AJScanlan/LedgerKit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

LedgerKit is a durable conversation-state engine for Foundation Models apps on
Apple platforms. It gives you an append-only ledger of everything that happened
in a conversation, a typed message-lifecycle state machine the compiler makes you
handle, and a reconciliation layer between durable app state and the ephemeral
`LanguageModelSession`.

Apple owns inference. LedgerKit owns what the platform leaves to you: **state
that survives the app being killed mid-stream.**

> **TODO(gif):** `Documentation/assets/dod1.gif` — the app is killed mid-generation
> and relaunched. No recovery code runs: the partial text is already in the log, and
> the absence of a terminal event is what makes the message `.interrupted`.

**[Why not just persist the transcript?](#why-not-just-persist-sessiontranscript)** ·
**[Quickstart](#quickstart)** ·
**[Message states](#the-five-states-and-why-the-compiler-makes-you-handle-them)** ·
**[Swapping providers](#swapping-providers)** ·
**[Testing](#testing-with-understudy)** ·
**[Requirements](#requirements)**

---

## Why not just persist `session.transcript`?

This is the right first question, and it deserves answering before any code.

`Transcript` is `Codable`. You can encode it into SwiftData with
`@Attribute(.externalStorage)`, reload it through the transcript-seeding
initializer, and be done in twenty lines. Every tutorial recommends it. It is the
null hypothesis, and it is genuinely fine right up until one of these matters:

| A transcript blob… | …and so |
|---|---|
| **has no message lifecycle** | `failed`, `cancelled` and `interrupted` are indistinguishable from *absent*. A turn that went wrong looks exactly like a turn that never happened. |
| **loses mid-stream partials entirely** | The transcript holds *completed* turns. Kill the app while a response is streaming and the text the user was reading is simply gone. |
| **is linear** | No edit-as-branch, no regenerate-as-sibling, no branch switcher. Editing a message means destroying what came after it. |
| **rewrites invisibly** | Every save is a full-state overwrite. There is no audit trail, no history, and no way to answer "what did the model actually see?" |
| **has no recovery semantics** | Beyond "whatever was last encoded," there is nothing. |

LedgerKit exists because the null hypothesis fails five ways, and because each
failure is the kind you discover in production rather than in review.

The mechanism is event sourcing: state is a deterministic fold over an
append-only log. Nothing is ever overwritten, so "the app died mid-stream" is not
a special case to handle — it is just a log whose last generation has no terminal
event, and the reducer derives `.interrupted` from that absence without being
told.

---

## Quickstart

Add the package:

```swift
// Package.swift
.package(url: "https://github.com/AJScanlan/LedgerKit.git", from: "0.1.0")
```

```swift
.product(name: "LedgerKit", package: "LedgerKit")
```

Open a store, pick a provider, and send a turn:

```swift
// Source: Tests/LedgerKitTests/APISketchTests.swift
import FoundationModels
import LedgerKit

let store = try ConversationStore(persistence: .sqlite(at: databaseURL))
let driver = GenerationDriver(model: SystemLanguageModel.default)

let conversation = try await store.createConversation()
try await store.setInstructions("You are an origami tutor.", in: conversation.id)

let outcome = try await store.send(
    "Explain valley folds",
    in: conversation.id,
    using: driver
)
```

`send` suspends until the generation reaches exactly one terminal outcome —
`.completed`, `.failed` or `.cancelled`. It throws **only** if the generation
never started; once the ledger has recorded that a generation began, every
failure after that point is an outcome rather than an exception. One channel for
"couldn't record", one for "recorded a failure."

For the UI, attach an observable projection. It is `@MainActor`, `@Observable`,
and receives streaming deltas at display cadence rather than at disk-flush
cadence:

```swift
// Source: Projection/Projection/ChatScreen.swift
let projection = try await ConversationProjection(of: conversation.id, in: store)

ForEach(projection.conversation.activeMessages) { message in
    MessageBubble(message: message)
}
```

That is the whole loop: a store, a driver, a projection.

---

## The five states, and why the compiler makes you handle them

`MessageState` is the type the rest of the library exists to produce. It has five
cases, and because it is a closed enum, SwiftUI's `switch` will not compile until
you have said what each one looks like:

```swift
// Source: Tests/LedgerKitTests/APISketchTests.swift
switch message.state {
case .complete(let content):
    Text(content.text)

case .streaming(let partial):
    Text(partial) + TypingIndicator()

case .interrupted(let partial):
    // The app died mid-stream. The partial survived; offer to continue.
    Text(partial); RegenerateButton()

case .cancelled(let partial):
    Text(partial); Label("Stopped", systemImage: "stop.circle")

case .failed(let partial, let error, let recoverability):
    Text(partial)
    switch recoverability {
    case .retryable(let after):             RetryButton(after: after)
    case .recoverableUpstream(let action):  FixItButton(action)          // e.g. enable Apple Intelligence
    case .terminal:                         ErrorLabel(error)
    }
}
```

Two things are load-bearing here.

**`.interrupted` is derived, not recorded.** Nothing writes it. It is what the
reducer concludes when a generation has a start and no terminal — which is
exactly the state a crash leaves behind. You cannot forget to handle a crash,
because the compiler will not let you.

**`.streaming` can only ever appear in a projection.** No fold of any log yields
it, because a log is a record of what happened and nothing is "currently
happening" in a record. That is why a message cannot be simultaneously streaming
and failed: the type system forbids it rather than a convention discouraging it.

### Recoverability

Every failure carries an affordance, not just an error. `Recoverability` is
**derived at classification time and persisted nowhere**, which means fixing a
mapping retroactively upgrades the affordances on historical failures the next
time they are read. Classification bugs heal; frozen classifications don't.

The default mapping:

| Error | Recoverability |
|---|---|
| `modelUnavailable(.deviceNotEligible)` | `terminal` |
| `modelUnavailable(.appleIntelligenceNotEnabled)` | `recoverableUpstream(.enableAppleIntelligence)` |
| `modelUnavailable(.modelNotReady)` | `recoverableUpstream(.awaitModelDownload)` |
| `contextSizeExceeded` | `recoverableUpstream(.reduceContext)` |
| `guardrailViolation` | `terminal` |
| `refusal` | `terminal` |
| `unsupported(*)` | `terminal` — three of the four are configuration errors, so the developer is the audience |
| `rateLimited(after)` | `retryable(after)` |
| `transport(*)` | `retryable(nil)` |
| `providerFailure`, 5xx | `retryable(nil)` |
| `providerFailure`, 401 / 403 / 407 | `recoverableUpstream(.reauthenticate)` |
| `providerFailure`, other 4xx | `terminal` |
| `providerFailure`, no status | `terminal` — per-provider `code` overrides apply first |
| `unrecognized` | `terminal` |

An unclassifiable failure retried blind risks a retry loop on a permanent fault,
so the default is `terminal` — which still leaves Regenerate as the manual retry.
Override per-case on the projection, not the store:

```swift
// Source: Tests/LedgerKitTests/APISketchTests.swift
var lenient = RecoverabilityMapping.default
lenient.guardrailViolation = .retryable(after: .seconds(5))

let projection = try await ConversationProjection(of: id, in: store, mapping: lenient)
```

---

## Branching

Editing a message does not destroy what came after it. An edit is a new branch;
the old one stays in the log and stays reachable.

```swift
// Source: Tests/LedgerKitTests/APISketchTests.swift
let replacement = try await store.edit(message.id, content: "Explain mountain folds", in: id)
try await store.respond(to: replacement, in: id, using: driver)   // generate down the new branch

try await store.regenerate(assistant.id, in: id, using: driver)   // sibling response
try await store.switchBranch(to: replacement, in: id)             // back to the other one

// Every version of a message, including itself, in creation order —
// what a ‹ 2 of 3 › pager is built from.
let versions = conversation.messages.versions(of: message.id)     // [Message]
```

`edit` is pure ledger — it records the edit and moves the active path, and
deliberately does **not** generate. What to do next is your app's decision, not
the library's.

---

## Swapping providers

LedgerKit consumes `any LanguageModel`. It never wraps or re-exports Apple's
inference types, so switching providers is a one-line change, and the ledger
records which model produced which message:

```swift
// on-device
let driver = GenerationDriver(model: SystemLanguageModel.default)

// a server model, via its own provider package
let driver = GenerationDriver(
    model: anthropic,
    descriptor: ModelDescriptor(provider: "anthropic", model: "claude-sonnet-4-5")
)
```

> **TODO(gif):** `Documentation/assets/dod2.gif` — the same conversation continued
> against a different provider, with the log recording `provider: "anthropic"` on
> the new generation.

The descriptor is durable wire data: two apps spelling the same model differently
would make one model look like two in the log, which is why
`ModelDescriptor.appleSystem` is a shared constant rather than a string you retype.

**What is claimed here, precisely.** The swap is one line, and the log records which
provider answered. What is *not* claimed is that any given vendor's package stays
buildable across SDK releases — that is the vendor's release cadence, not this
library's. Concretely, as of Xcode 27.0: Apple's Private Cloud Compute provider needs
an entitlement, and no tagged release of `ClaudeForFoundationModels` builds against
the 27 SDK. The demo's Claude wiring therefore lives on the unmerged branch
`m8-dod2-claude` rather than on `main`, because pinning `main` to a provider that
does not currently build would be a worse promise than not making one. The recorded
demonstration and the log line are the evidence; the vendor's name in a build file
is not.

---

## Testing with Understudy

`Understudy` ships in this package as a **separate product**. It has no dependency
on LedgerKit and is useful to any Foundation Models app, whether or not you use
the rest of this library:

```swift
.product(name: "Understudy", package: "LedgerKit")
```

`ScriptedLanguageModel` conforms to Apple's real `LanguageModel` protocol and
plays a script. No network, no Apple Intelligence eligibility, no model download,
and the same output on every run:

```swift
// Source: Tests/LedgerKitTests/DriverPipelineTests.swift
import Understudy

let model = ScriptedLanguageModel(script: [
    .emit("A valley fold "),
    .emit("creases toward you."),
])
```

A script can also do the things a real provider does at the worst possible
moment: `.wait(_:)` paces a stream, `.wait(until:)` parks it on a cue so a test
can kill the app mid-generation deterministically, `.fail(_:)` raises a provider
error, and `.callTool(_:arguments:)` drives a real tool exchange. That is how
LedgerKit tests its own crash-recovery path, and it is available to you for the
same purpose.

> You depend on `LedgerKit` the *package* to get `Understudy`, but you do not
> **link** LedgerKit — SPM builds only the product you name.

---

## What LedgerKit does not do

These are non-goals **forever**, not just for v0.1. Apple owns this half of the
boundary and LedgerKit will not rebuild it:

- The inference protocol (`LanguageModel`, `LanguageModelExecutor`) — consumed, never wrapped
- Provider packages: on-device, Private Cloud Compute, Claude, Gemini, Chat Completions
- The in-session transcript, context window, and in-session compaction
- Prompt patterns, the Skills API, guided generation
- Tool *execution* — LedgerKit records an audit trail of invocations; the session runs them
- Auth and billing for server models
- Evaluations

If you want a library that abstracts over providers, this is not it — and the
fact that it isn't is why swapping one is a single line.

---

## Requirements

- **Xcode 27** — LedgerKit deploys to iOS/macOS 26 but *compiles* against the 27 SDK
- **iOS 26+ / macOS 26+** — the package floor
- **Swift 6 language mode**, strict concurrency throughout. No `@unchecked Sendable` in public API.

The `Session/` module, which is the only part coupled to Foundation Models, is
availability-gated to 27. Everything else — the ledger, the reducer, the store,
the projection — builds and runs on 26, and is tested on any Mac with no Apple
Intelligence eligibility required.

---

## Versioning before 1.0

LedgerKit is pre-1.0, and the two things it guarantees across versions are **not
the same thing**.

**Source compatibility follows SemVer's pre-1.0 rules.** A minor bump (`0.1` →
`0.2`) may break your build. Public names, signatures and enum cases are still
moving.

**Wire compatibility does not.** An event log written by any released version
reads in every later one, whatever the version numbers say. That promise is
governed by [ADR-001](Documentation/ADR/ADR-001-event-encoding.md) — a
discriminator registry where tags are never reused and retired tags stay reserved
forever — and enforced by a version-frozen fixture corpus that CI replays on every
run. Your users' conversation history is not the part that is in flux.

### Which enums you may switch exhaustively

Swift lets you `switch` over a public enum with no `default`, and a library that
later adds a case breaks that switch. LedgerKit therefore splits its public enums
in two, and the split is itself a promise.

**Stable — switch exhaustively, no `default` needed.** `MessageState`,
`Recoverability`, `Role`, `Outcome`, `Status`. These describe closed domains, and
they are *designed* so that growth lands somewhere else: new information attaches
to `Message` or extends `MessageContent` rather than adding a case.
`MessageState`'s five-case switch is the API this library is built around, and it
is meant to keep compiling.

**Growable — write a `default`.** `Payload`, `QuarantineReason`, `LedgerError`,
and `GenerationError` with its nested `ModelUnavailability`, `UnsupportedFeature`
and `TransportFailure`. These are open taxonomies of things the world does, and
they are expected to grow: `Payload` gains kinds as the ledger learns to record
more, `QuarantineReason` gains one whenever a new corruption becomes
distinguishable, and `GenerationError` already ships `unrecognized` as its floor
precisely so an unanticipated provider failure has somewhere to land.

Switch only the stable set and a minor bump will not break *those* switches.
Switch the growable set exhaustively and expect to revisit it.

---

## Privacy

Conversations are user content, and LedgerKit treats them that way.

**No telemetry, ever.** Nothing is phoned home, counted, or sampled.

**File protection.** On the iOS family, LedgerKit applies
`.completeUntilFirstUserAuthentication` to the database and its sidecars.
(`FileProtectionType` is an iOS-family concept; the macOS equivalent is FileVault,
which is not a library's to set.) Two gaps are owned rather than hidden: the `-wal`
and `-shm` files do not exist until the first write, so they are protected on the
*next* open rather than the first; and the robust answer is protection on the
containing **directory**, which belongs to whoever chose it — your app. An app in a
sensitive domain should set that, and should layer its own encryption.

**Tool recording defaults to `.metadataOnly`**, because a recorded tool result
outlives the session that produced it. Opt into full argument and result capture
only when you want that on disk.

**Deletion is real deletion.** `deleteConversation` cancels any in-flight
generation, waits it to its terminal, then transactionally removes that
conversation's events, snapshots and index row. It is out-of-band — not an event,
because there is no log left to append to — and it is irreversible.

One honest limitation, stated because it is structural rather than a to-do:
**append-only storage and erasure are opposed by construction.** Deleting a whole
conversation is clean; redacting a *message* from within a log that is defined by
never overwriting anything is not. The two known idioms are crypto-shredding
(encrypt payloads under per-conversation keys; deleting the key is the erasure)
and an explicit versioned log rewrite. Choosing one is a v0.2 design question, and
message-level redaction is out of scope until then.

---

## Documentation

This repository is unusually documented, because the design is unusually
load-bearing:

- **[SPEC.md](Documentation/SPEC.md)** — the contract. Semantics defined here are binding; every invariant, quarantine rule and error mapping is specified rather than implied.
- **[ADR-001](Documentation/ADR/ADR-001-event-encoding.md)** — event encoding, the discriminator registry, and the evolution rules the wire promise rests on.
- **[ADR-002](Documentation/ADR/ADR-002-identifiers.md)** — identifiers.
- **[ADR-003](Documentation/ADR/ADR-003-persistence-dependency.md)** — persistence and the six-verb storage seam.
- **[ROADMAP.md](Documentation/ROADMAP.md)** — what is built and what is next.

The test suite is part of the argument rather than an afterthought: golden-log
fixtures, hostile fixtures mirroring every quarantine rule row-for-row,
crash-point fuzzing that truncates every fixture at every prefix, bounded
exhaustive generated-log sweeps, and a TLA+ model of the store's interleavings.

---

## Status

Pre-1.0 and under active development toward `0.1.0`. The library is feature
complete against its spec, and both definition-of-done demonstrations — recovering
from a mid-stream kill, and swapping providers in one line — are implemented and
recorded.

## License

MIT. See [LICENSE](LICENSE).
