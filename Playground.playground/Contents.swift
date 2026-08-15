import Foundation
import LedgerKit
import PlaygroundSupport
import SwiftUI
import UIKit

// **The 60-second tour: a conversation is a fold over a log.**
//
// This file builds a short event log by hand and reduces it. That is deliberately
// the *only* way in — `Message`, `MessageTree` and `Conversation`'s memberwise
// initializers went internal at M4 Phase 0, because they can express states no
// log can produce (a `.user` message that is `.streaming`, an `activePath` that is
// not a chain). Tenet 2's "the log is the truth" is only structurally true if the
// log is the sole way to obtain derived state.
//
// Until M7 Phase 0 this file hand-assembled a tree behind `@testable import`,
// which made it a demonstration of the one thing a consumer cannot do. Reducing a
// log is the better example anyway: it exercises the real semantics, so the tree
// below is one the reducer built rather than one this file asserted.
//
// Note on identifiers: passing a v4 `UUID` where v7 is intended is deliberately
// unpreventable. Decode must accept whatever UUIDs are in historical logs, so
// v7-ness is a property of the generator (`IDGenerator`), not of the type. In an
// app the store mints these and you never write one.

let conversationID = ConversationID(UUID())
let firstQuestion = MessageID(UUID())
let answer = MessageID(UUID())
let rateLimited = MessageID(UUID())
let thanks = MessageID(UUID())
let generationA = GenerationID(UUID())
let generationB = GenerationID(UUID())

/// Numbers rows the way the store's write transaction does, so a hand-built log
/// is shaped like a real one.
///
/// A value type rather than a pair of mutable globals, for a reason worth knowing:
/// under Swift 6 top-level `var`s are `@MainActor`-isolated while a free `func` is
/// not, so a global-mutating helper does not compile. Threading the state through
/// a `mutating` method sidesteps the question entirely — which is the same shape
/// the package's own test-side log builder uses.
struct LogBuilder {
    let conversation: ConversationID
    private(set) var rows: [LoadedEvent] = []
    private var sequence: Int64 = 0

    mutating func append(_ payload: LedgerEvent.Payload) {
        sequence += 1
        // A `Record` is what a writer hands the store; the store returns the same
        // value carrying its assigned `sequence`. That asymmetry is why there is
        // no public initializer taking a sequence directly — `sequence` lives
        // only in the events-table key (§6.1), and nothing above the persistence
        // seam is entitled to choose one.
        let record = LedgerEvent.Record(
            id: EventID(UUID()),
            conversationID: conversation,
            // Display and audit only — the reducer never reads a timestamp, which
            // is what keeps I1 (determinism) free of wall-clock influence.
            timestamp: Date(timeIntervalSince1970: 1_784_979_000 + Double(sequence)),
            payload: payload
        )
        rows.append(.decoded(LedgerEvent(record: record, sequence: sequence)))
    }
}

// One event per line, in the order they were appended.
var log = LogBuilder(conversation: conversationID)

// Genesis: sequence 1, exactly once. Anything before it, or a second one,
// quarantines (§6.6 row 5).
log.append(.conversationCreated(title: "Capitals"))
log.append(.userMessageAppended(message: firstQuestion, content: "What's the capital of Ireland?", parent: nil))

// A generation that completed. The assistant message exists *only* as the product
// of this generation — there is no event that appends assistant text directly,
// which is what makes the audit trail trustworthy (§6.1).
log.append(.generationStarted(generation: generationA, message: answer, parent: firstQuestion,
                          model: ModelDescriptor(provider: "apple", model: "system")))
log.append(.deltaAppended(generation: generationA, text: "Dub"))
log.append(.deltaAppended(generation: generationA, text: "lin"))
log.append(.generationEnded(generation: generationA, outcome: .completed(StopInfo())))

// A regenerate that failed: a *sibling* of the message above, under the same
// parent. The old answer survives on its own branch — this is §6.4's
// "regenerate-as-sibling" falling out of the model rather than being a feature.
// Its parent is not the current path endpoint, so the store pairs the start with
// an `activePathChanged` in the same transaction: a generation the user asked for
// must never stream invisibly.
log.append(.generationStarted(generation: generationB, message: rateLimited, parent: firstQuestion,
                          model: ModelDescriptor(provider: "apple", model: "system")))
log.append(.activePathChanged(endpoint: rateLimited))
log.append(.generationEnded(generation: generationB, outcome: .failed(.rateLimited(retryAfter: .seconds(30)))))

// Back to the completed branch, and a follow-up on it. A bare `activePathChanged`
// is exactly what a branch switcher emits.
log.append(.activePathChanged(endpoint: answer))
log.append(.userMessageAppended(message: thanks, content: "Thank you", parent: answer))

// `classify ∘ fold`, and the only public way to obtain a `Conversation` (§6.3).
//
// Two things worth noticing in the result. `Recoverability` on the failed branch
// was **not** persisted — it is derived here, by the mapping, which is why fixing
// a mapping retroactively upgrades the affordances on historical failures (§8).
// And nothing in this log says "interrupted": had the `generationEnded` above been
// missing — a process killed mid-stream — the reducer would synthesize
// `.interrupted` from its *absence* (I5). That absence is the entire crash-recovery
// mechanism: no dirty flags, no repair pass.
let conversation = Conversation(reducing: log.rows, loadedFrom: conversationID)

// Empty on a healthy log. A non-empty `diagnostics` means damage, partial restore,
// or a *newer* LedgerKit wrote this log (§6.5's healthy-log property).
print("diagnostics: \(conversation.diagnostics.map { $0.description })")
print("active path: \(conversation.activeMessages.count) messages")
print("branches at the answer: \(conversation.messages.siblings(of: answer).count)")

let view = ConversationView(conversation: conversation)
PlaygroundPage.current.liveView = UIHostingController(rootView: view)
