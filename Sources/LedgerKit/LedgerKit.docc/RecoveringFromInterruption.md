# Recovering from an interruption

What happens to a conversation when the process dies mid-stream, and why no
recovery code runs.

## Overview

An app is streaming a response. The user switches away, the system reclaims
memory, and the process is gone. On relaunch the message reads
``MessageState/interrupted(partial:)``, carrying the text that had reached disk,
and the user is offered a way to continue.

No recovery routine runs to make that happen. There is no `recover()`, no repair
pass, no "was I mid-generation?" flag checked at launch. This article explains why
the absence is the mechanism rather than an omission.

## The log a crash leaves behind

A healthy generation writes a start event, some number of text deltas, and exactly
one terminal — completed, failed, or cancelled. A process death writes the start
and the deltas, then stops. The terminal never arrives, because the code that
would have written it no longer exists.

So the crash leaves a log that is not corrupt and not truncated in any way the
reader has to detect. It is simply a log whose last generation has a beginning and
no end. That is a shape the reducer can recognise without being told a crash
occurred — and it cannot be confused with anything else, because a generation that
failed or was stopped has a terminal event saying so.

## Three names for one message

The same message carries three different names as it moves outward through the
library, and reading them right to left is the whole of crash recovery.

| Layer | Name | Means |
| --- | --- | --- |
| Reducer's internal fold | `.open` | a generation started and has not ended |
| Public classification | ``MessageState/interrupted(partial:)`` | …and nothing is going to end it |
| Projection overlay | ``MessageState/streaming(partial:)`` | …except that it is running *right now* |

The fold's job is to state what the log says: this generation is open. Turning
`.open` into `.interrupted` happens in classification, and it is the correct
reading, because a log is a record of the past — an open generation in a *record*
is one that never finished.

`.streaming` is then the exception, applied by ``ConversationProjection`` only for
generations the store currently has in flight. It is the overlay saying "this
particular open generation is open because it is happening, not because it died."

A relaunched process has nothing in flight. Its live set is empty, so the overlay
is the identity function, and `.interrupted` — already what the fold concluded —
is what the app sees. Recovery is not a step that runs; it is the absence of a
step that would have overridden it.

## What comes back

Exactly what reached disk, which is governed entirely by ``DeltaFlushPolicy``.

Writing every token to SQLite is wasteful; losing thirty seconds of stream to a
crash is bad UX. The policy is where an app chooses between them, and its meaning
is precise: **the unflushed tail is what a crash costs, and nothing else is.**

```swift
let store = try ConversationStore(
    persistence: .sqlite(at: url),
    deltaFlush: .flushing(every: .seconds(2), orAfterCharacters: 200)
)
```

Whichever comes first. One detail is easy to get wrong and worth stating plainly:
**the character buffer resets after each flush**, so the bound applies to each
accumulation independently rather than cumulatively across the generation. With a
bound of 8 characters, a 14-character delta flushes and clears; a following 6 and
then 7 never reach 8 on their own and stay buffered.

LedgerKit's own test asserts this as arithmetic rather than describing it. It
streams `"A valley fold "` (flushed), then `"brings"` and `"!"` (buffered),
abandons the generation without a terminal, and reopens over the same database
with a cold cache:

```swift
// on screen before the kill
.streaming(partial: "A valley fold brings!")

// after relaunch
.interrupted(partial: "A valley fold ")

// and the difference is exactly the tail the policy had not written
onScreen.visibleText == afterCrash.visibleText + "brings!"
```

That equation is the honest claim of the design. Recovery does not return
everything the user saw; it returns everything that was durably written, and the
gap is a number the app chose.

## What this costs

Only `deltaAppended` coalesces. Every other event — the generation start,
terminals, edits, path changes, metadata — is written immediately, so the
structure of a conversation is never at risk from a crash. What a flush policy
trades is the tail of streamed *text*, and nothing structural.

## Topics

### Related

- ``MessageState``
- ``DeltaFlushPolicy``
- ``ConversationProjection``
- ``ConversationStore``
