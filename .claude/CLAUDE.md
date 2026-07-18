# LedgerKit

Durable conversation-state engine for Foundation Models apps on Apple platforms (iOS/macOS 27). It is an event-sourced ledger of conversation history, a typed message-lifecycle state machine, and a reconciliation layer between durable app state and the ephemeral `LanguageModelSession`. Positioning: *"the state layer Foundation Models doesn't ship."* Pre-1.0, targeting a `0.1.0` tag before iOS 27 GA (~Sept 2026).

## Two source-of-truth documents

- **`Documentation/SPEC.md`** — the **contract** (currently rev 4). Semantics defined here are binding; type names in it are illustrative ("bikesheddable; semantics not").
- **`Documentation/ROADMAP.md`** — the **build order** (milestones M0–M9).
- **On any conflict, the spec wins and the roadmap is stale — fix the roadmap.** (The roadmap states this rule itself.)

Read the relevant spec section before implementing anything in this repo; the design is unusually load-bearing and most "obvious" simplifications are already-considered non-goals.

## Commands

There is **no `Package.swift` at the repo root.** Two independent SPM packages live in subdirectories, so every `swift` command must target one explicitly:

```bash
swift build --package-path LedgerKit
swift test  --package-path LedgerKit
swift build --package-path LedgerKitTestSupport
swift test  --package-path LedgerKitTestSupport
```

- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`) — not XCTest.
- Toolchain: Swift 6.3 (Xcode 26.6), **Swift 6 language mode, strict concurrency**.
- `LedgerKit.xcworkspace` ties together both packages, the `Projection` demo app, `Documentation/`, and a playground. Build the demo app from the workspace in Xcode (scheme `Projection`).

## Architecture

**Boundary rule (SPEC §2): Apple owns inference; LedgerKit owns durable state.** LedgerKit consumes `any LanguageModel` / `LanguageModelSession` and never wraps or re-exports them. Everything in the left column of the §2 boundary map (inference protocol, providers, in-session transcript/compaction, tool execution) is a non-goal *forever*, not just for v0.1.

Three products, one workspace:

- **`LedgerKit/`** — the library. Source tree is scaffolded but mostly empty, filled per milestone:
  - `Core/` — event log + derived-state types (SPEC §6.1–6.2). This is **wire format = API forever**; adding an event kind is a permanent commitment.
  - `Reduce/` — the pure reducer, `fold → classify` (§6.3, invariants I1–I7). **The load-bearing wall:** `nonisolated`, deterministic, no clocks, no I/O. Persistence, the store, the projection, and the demo are all downstream of a correct fold.
  - `Store/` — SQLite persistence + snapshots + index, the `ConversationStore` actor, and the turn verbs (§9, §6.5, §11).
  - `Session/` — the `GenerationDriver`, the one OS-coupled module (§7). **All iOS-27-beta risk (the ⚠️ / OQ1–9 items) is isolated here and nowhere else.**
  - `Projection/` — the `@MainActor @Observable` read side + `overlay_live` (§6.2, §7.4).
- **`LedgerKitTestSupport/`** — ships `ScriptedLanguageModel`, a deterministic `LanguageModel` test double. A separate product on purpose ("the gateway drug" — useful to any Foundation Models app, and lets the whole library test with zero network and zero Apple Intelligence eligibility).
- **`Projection/`** (top-level Xcode app) — the demo (kill-mid-stream recovery + one-line provider swap).

⚠️ **Naming collisions to keep straight:** the top-level `Projection/` *app* is distinct from `LedgerKit/Sources/LedgerKit/Projection/` (the internal observable-projection layer). The roadmap still calls the demo app **"Scroll"** and references deleted `Data/Models/ChatEvent.swift` stubs — both are stale; the app is `Projection` and those stubs were removed at M0.

## Design tenets (constrain every change — SPEC §3)

1. **Illegal states unrepresentable** — closed enums; never an `isLoading: Bool` beside an `error: Error?`. A message cannot be simultaneously streaming and failed.
2. **Event-sourced: the log is the truth** — state is a deterministic fold over an append-only log. Snapshots, the conversation index, and the observable projection are all derived, rebuildable, and deletable.
3. **The inference boundary is Apple's** — never wrap or re-abstract `LanguageModelSession` / `any LanguageModel`.
4. **Signals cannot be skipped** — every generation ends in exactly one terminal outcome (completed/failed/cancelled) or is derivably `.interrupted`.
5. **Test doubles are first-class** — see `ScriptedLanguageModel`.
6. **Strict concurrency clean** — no `@unchecked Sendable` in public API; the reducer is pure and isolated from UI.

## Working discipline

- **Build order is deliberate:** pure core (M1–M5) is fully built and tested before the beta-coupled `Session/` seam (M6). M1–M5 verify on any Mac; only M6 re-opens per iOS 27 beta. Don't pull `Session/` work forward.
- **Never cut, even under time pressure:** invariants I1–I7 and property tests P1–P3, interruption recovery, and `ScriptedLanguageModel`.
- **Testing *is* the product differentiation:** golden-log fixtures (snapshot-tested), hostile fixtures mirroring the §6.6 quarantine table row-for-row, crash-point fuzzing (truncate every fixture at every prefix — "the single highest-value suite"), and property tests P1–P3.
- **Persistence backend is deliberately undecided** (GRDB vs. raw sqlite3, behind a small protocol) — don't bikeshed it early. **SwiftData is explicitly the wrong shape** for an append-only log; don't reach for it.
- **Status:** M0 done (package split + empty `Core/Reduce/Store/Session/Projection` scaffolding). M1+ not started — source files are placeholder stubs.

## Conventions & workflow preferences

<!-- TODO(human): Fill in your working preferences for this repo — the rules you want
     followed that can't be inferred from the code. See the "Learn by Doing" request. -->
- **Test rhythm**
  - Test Driven Development
  - Do not mark a milestone done without all tests passing
- **Documentation**
  - Update `ROADMAP.md` freely if it's stale
  - Do not edit `SPEC.md` without asking
- **Milestone discipline**
  - Prioritize milestone order, but exploratory spikes allowed when valuable
- **Commits/PRs**
  - Do not commit without asking
- **Code style**
  - Follow Swift Package idioms and best practices
  - Structure types in the following order
    - Public/Internal/Private inner types
    - Public/Internal/Private static properties
    - Public/Internal/Private properties
    - Init/Deinit
    - Public/Internal/Private static functions
    - Public/Internal/Private functions