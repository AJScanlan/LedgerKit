# Handling message states

Rendering every state a message can be in, and letting the compiler prove none
were missed.

## Overview

``MessageState`` is the type the rest of LedgerKit exists to produce. It has five
cases and no `default` is needed, so a `switch` over it does not compile until
each one has an interface.

```swift
switch message.state {
case .complete(let content):
    Text(content.text)

case .streaming(let partial):
    Text(partial) + TypingIndicator()

case .interrupted(let partial):
    Text(partial)
    Button("Continue") { … }

case .cancelled(let partial):
    Text(partial)
    Label("Stopped", systemImage: "stop.circle")

case .failed(let partial, let error, let recoverability):
    Text(partial)
    affordance(for: recoverability, error)
}
```

Every case except `.complete` carries a partial. That is deliberate: text the user
already read is text the app should keep showing, whatever happened afterwards.

### Two facts that are easy to miss

**`.interrupted` is derived, never recorded.** No event writes it. It is what the
reducer concludes when a generation has a start and no terminal, which is exactly
the shape a crash leaves in the log. An app cannot forget to handle a crash,
because the crash state is one of the five cases the compiler insists on. See
<doc:RecoveringFromInterruption>.

**`.streaming` can only appear in a projection.** No fold of any log produces it,
because a log records what happened and nothing is *currently happening* in a
record. It is applied by ``ConversationProjection`` as deltas arrive. This is why
a message cannot be simultaneously streaming and failed: the type makes the
combination unrepresentable rather than a convention discouraging it.

## Recoverability

A failure carries an affordance alongside its error. ``Recoverability`` has three
cases, and they correspond to what the app can offer rather than to what went
wrong:

```swift
switch recoverability {
case .retryable(let after):
    RetryButton(after: after)            // transient; retrying is reasonable

case .recoverableUpstream(let action):
    FixItButton(action)                  // the user must change something first

case .terminal:
    ErrorLabel(error)                    // retrying will not help
}
```

``RequiredAction`` names the four things a user can actually be asked to do:
enable Apple Intelligence, wait for a model download, reduce context, or
re-authenticate.

Three cases rather than one per error kind is a deliberate compression. There are
more ways for a generation to fail than there are useful responses to failure, and
a taxonomy sized to the failures rather than to the responses would put rows in
this `switch` that all render the same button.

### Recoverability is derived, not stored

``Recoverability`` is computed at classification time from the persisted
``GenerationError`` and is written nowhere — not into events, not into snapshots.

This has a useful consequence: correcting a mapping retroactively upgrades the
affordances on historical failures the next time they are read. Classification
bugs heal. Had the classification been persisted alongside the error, every
conversation stored before the fix would keep the wrong button forever.

### Overriding the mapping

Overrides belong on the projection, not the store, because classification happens
on read:

```swift
var lenient = RecoverabilityMapping.default
lenient.guardrailViolation = .retryable(after: .seconds(5))

let projection = try await ConversationProjection(of: id, in: store, mapping: lenient)
```

``RecoverabilityMapping/default`` ships LedgerKit's table. Its notable choice is
that an unclassifiable provider failure maps to `.terminal` rather than
`.retryable`: retrying blind risks a retry loop against a permanent fault, and
`.terminal` still leaves Regenerate as a manual retry the user controls.

## Topics

### Related

- ``MessageState``
- ``Recoverability``
- ``RequiredAction``
- ``RecoverabilityMapping``
- ``GenerationError``
