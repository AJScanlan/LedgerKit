# ``LedgerKit``

A durable conversation-state engine for Foundation Models apps on Apple platforms.

## Overview

Apple's `LanguageModel` protocol owns inference. LedgerKit owns what the platform
leaves to the app: conversation state that survives the process being killed.

The design is event sourcing. Every fact about a conversation — a message
appended, a generation started, a fragment of text streamed, a generation ended —
is appended to a log and never overwritten. Conversation state is a deterministic
fold over that log, which makes it rebuildable, auditable, and testable without a
model in the loop.

One consequence is worth stating up front, because it is the reason the library
exists. A generation that started and has no terminal event did not fail and was
not cancelled: it was *interrupted*. Nothing records that state, and nothing needs
to. ``MessageState/interrupted(partial:)`` is what the reducer concludes from an
absence, so crash recovery is a property of the data model rather than a code path
somebody has to remember to write.

### Where to start

New readers should begin with <doc:WhyNotPersistTheTranscript>, which answers the
question most readers arrive with, and then <doc:HandlingMessageStates>, which
covers the type the rest of the library exists to produce.

### The three moving parts

``ConversationStore`` is the only thing that writes. It owns identity, canonical
timestamps and the single-flight rule that prevents two concurrent generations in
one conversation, and it exposes the turn verbs — `send`, `respond`, `regenerate`,
`edit`, `switchBranch`.

``GenerationDriver`` is the seam to Foundation Models, and the only module coupled
to it. It consumes `any LanguageModel`, normalizes provider errors into
``GenerationError``, and reports exactly one ``Outcome``.

``ConversationProjection`` is the read side: `@MainActor`, `@Observable`, and fed
by the store. It applies streaming partials at display cadence rather than at
disk-flush cadence, which is why a UI can show smooth text without the log growing
a row per character.

## Topics

### Essentials

- <doc:WhyNotPersistTheTranscript>
- <doc:HandlingMessageStates>
- <doc:RecoveringFromInterruption>

### Reading a conversation

- ``Conversation``
- ``Message``
- ``MessageState``
- ``MessageContent``
- ``MessageTree``
- ``Role``
- ``ConversationSummary``

### Storing and driving

- ``ConversationStore``
- ``PersistenceConfiguration``
- ``GenerationDriver``
- ``GenerationDriving``
- ``ModelDescriptor``
- ``Outcome``
- ``StopInfo``
- ``TokenUsage``

### Observing state

- ``ConversationProjection``
- ``ConversationListProjection``

### Errors and recovery

- ``GenerationError``
- ``ModelUnavailability``
- ``UnsupportedFeature``
- ``TransportFailure``
- ``Recoverability``
- ``RequiredAction``
- ``RecoverabilityMapping``
- ``LedgerError``

### The event log

- ``LedgerEvent``
- ``LoadedEvent``
- ``QuarantinedEvent``
- ``QuarantineReason``

### Tools

- ``ToolRecord``
- ``ToolRecordingPolicy``

### Tuning

- ``DeltaFlushPolicy``
- ``SnapshotPolicy``

### Identifiers

- ``ConversationID``
- ``MessageID``
- ``GenerationAttemptID``
- ``EventID``
- ``LedgerIdentifier``
- ``IDGenerator``
