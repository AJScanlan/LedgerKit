# ``Understudy``

A deterministic `LanguageModel` test double for Foundation Models apps.

## Overview

``ScriptedLanguageModel`` conforms to Apple's real `LanguageModel` protocol and
plays a script instead of running inference. No network, no Apple Intelligence
eligibility, no model download, and the same output on every run.

Understudy is useful to any app built on Foundation Models. It does not depend on
LedgerKit and nothing here assumes it.

```swift
import Understudy

let model = ScriptedLanguageModel(script: [
    .emit("A valley fold "),
    .emit("creases toward you."),
])
```

The model can then be handed to a `LanguageModelSession` anywhere a real one would
go, and the session will stream exactly those two fragments.

### Why a double rather than a small real model

A test that runs inference is a test of the model. It is slow, it varies run to
run, it needs entitlements the CI machine may not have, and when it fails the
first question is always whether the code or the model changed.

A script removes all four questions. What remains under test is the code that
consumes a stream — which is usually where the interesting bugs are, because
streams fail in ways that are hard to reproduce on purpose.

### Scripting the awkward cases

The value of a double is mostly in what it can be made to do at the worst possible
moment. ``Script/Step`` covers the cases a real provider will eventually produce
and never on demand:

| Step | Produces |
| --- | --- |
| ``Script/Step/emit(_:segmentID:tokenCount:)`` | a text fragment |
| ``Script/Step/revise(_:segmentID:tokenCount:)`` | a *non-prefix* revision of an earlier segment |
| ``Script/Step/wait(_:)`` | a pause, to pace a stream realistically |
| ``Script/Step/wait(until:)`` | a park on a ``Cue``, so a test drives the timing |
| ``Script/Step/fail(_:)`` | a thrown provider error, mid-stream |
| ``Script/Step/callTool(_:arguments:id:tokenCount:)`` | a real tool invocation |

``Script/Step/wait(until:)`` is the one worth knowing about. It parks the stream
until the test says to continue, which turns "kill the app mid-generation" from a
timing gamble into a deterministic step:

```swift
let midStream = Cue()

let model = ScriptedLanguageModel(script: [
    .emit("A valley fold "),
    .wait(until: midStream),
    .emit("creases toward you."),
])

// …elsewhere, once the test is ready:
await midStream.reached()     // the stream has parked
// assert whatever should be true mid-generation
await midStream.signal()      // let it continue
```

### Tools need a capability

The framework only invokes tools on a model that declares it can call them, and
``ScriptedLanguageModel`` declares no capabilities by default. Pass the capability
explicitly when scripting a tool exchange:

```swift
let model = ScriptedLanguageModel(
    script: [.callTool("lookup", arguments: #"{"city":"Dublin"}"#)],
    capabilities: LanguageModelCapabilities([.toolCalling])
)
```

A tool call also costs **two** scripts rather than one: the framework runs the
tool, then asks the model again with the result. Use
``ScriptedLanguageModel/init(scripts:whenExhausted:capabilities:clock:)`` and
supply both.

### Running out of script

A model asked for more responses than it has scripts is a programming error by
default, and ``ScriptExhausted`` is thrown. ``ScriptExhaustion`` chooses a
different behaviour when a test deliberately drives more turns than it scripted.

## Topics

### Essentials

- ``ScriptedLanguageModel``
- ``Script``
- ``Script/Step``

### Controlling timing

- ``Cue``

### Exhaustion

- ``ScriptExhaustion``
- ``ScriptExhausted``

### Conformance details

- ``ScriptedLanguageModelExecutor``
