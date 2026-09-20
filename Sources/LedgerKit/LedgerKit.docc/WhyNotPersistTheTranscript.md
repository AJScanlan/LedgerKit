# Why not just persist the transcript?

Understanding what a `Transcript` blob can and cannot represent, and why
conversation state needs a different shape.

## Overview

`Transcript` is `Codable`. Encoding it into SwiftData with
`@Attribute(.externalStorage)` and reloading it through the transcript-seeding
initializer takes about twenty lines, and for a single linear conversation that
never fails and never gets interrupted, it works.

This article is the honest account of where it stops working. It is worth reading
before adopting LedgerKit, because if none of the limits below apply to the app
being built, the blob is the correct choice and this library is overhead.

### A blob has no message lifecycle

A transcript records turns that happened. It has no way to say that a turn was
attempted and failed, that the user stopped it, or that the process died while it
was streaming. All three are represented identically: by the turn's absence.

That matters because those three cases want three different interfaces. A failure
wants an error and a retry affordance. A cancellation wants no error at all — the
user did that on purpose. An interruption wants the partial text back and an offer
to continue. An app built on a blob cannot tell them apart, so it shows the same
thing for all three, which is usually nothing.

LedgerKit's ``MessageState`` carries the distinction in the type system, and
because it is a closed enum, a `switch` over it will not compile until every case
has been handled.

### A blob loses mid-stream partials

The transcript holds *completed* turns. While a response is streaming, the text
the user is reading exists only in memory.

This is the limit that decides the question for most apps, because it makes the
common failure unrecoverable. The user is reading a long answer, the system
reclaims memory, the app relaunches — and the answer is gone, with no trace that
it was ever there.

LedgerKit appends streamed text to the log as it arrives, on a flush policy the
app controls (see ``DeltaFlushPolicy``). What was durably written survives, and
what survives is shown. See <doc:RecoveringFromInterruption> for exactly how much
text comes back and why.

### A blob is linear

There is one sequence of turns. Editing a message means overwriting it and
discarding everything that followed, because there is nowhere else for the old
branch to live.

LedgerKit models a conversation as a tree with an active path through it. An edit
creates a sibling rather than replacing anything, regenerating creates another
sibling, and `switchBranch` moves the active path. Nothing is destroyed, so a
branch switcher is a read of data that already exists rather than a feature
requiring its own storage.

### A blob rewrites invisibly

Every save is a full-state overwrite. There is no record of what changed, when, or
in what order — which means there is no way to answer "what did the model actually
see when it produced this?" after the fact.

An append-only log answers that by construction: the events that preceded a
generation *are* the context it was given. This is the property that makes the
fixture corpus possible, and the fixture corpus is what lets the reducer's
semantics be tested against hand-written logs rather than against a live model.

### A blob has no recovery semantics

Beyond "whatever was last encoded," there is nothing to reason about. Recovery
becomes a question of whether the last save happened to land, which is not a
question an app can answer.

## The trade

None of this is free. An event log is more storage, more concepts, and a
reduction step between the data and the screen. What it buys is that every
question above has a mechanical answer rather than a judgement call, and that the
answers are testable without a model.

The boundary is deliberate in the other direction too. LedgerKit consumes
`any LanguageModel` and never wraps it, so inference, provider selection,
in-session compaction, guided generation and tool execution all remain Apple's.
The library that abstracts over providers is not this one — which is precisely why
changing provider is a single line.
