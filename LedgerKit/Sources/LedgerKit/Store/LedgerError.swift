import Foundation

/// Why a `ConversationStore` verb never started (SPEC §11, §7.2; M5-PLAN D22).
///
/// **This is one half of a two-channel contract, and the halves are disjoint by
/// construction.** `try` guards *did it start*; the return value and the observed
/// state answer *how did it end*. Every case below is a failure detected
/// **before** the verb's first append, so a throw means the log is untouched —
/// no rows, no consumed sequence numbers, no index update (§9's all-or-nothing
/// batch). After the append there are no `LedgerError`s at all: failures are
/// `Outcome.failed`, including zero-token ones like an auth rejection, because
/// an error thrown into a `Task` nobody is switching over could never render
/// §11's reauth bubble.
///
/// One other error type crosses the throw channel and is deliberately not a case
/// here: `CancellationError`, when the verb's task is cancelled *before* the
/// append (§7.2). Nothing started, so Swift's convention holds and borrowing it
/// costs nothing; folding it into this enum would imply LedgerKit had an opinion
/// about a condition it merely observes.
///
/// An **enum**, where ``PersistenceConfiguration`` is a struct with factories —
/// D12's rule cutting the other way, and this is the side it was written for.
/// Consumers *destructure* errors; that is what a typed error is for, and an
/// error you cannot switch over exhaustively is a `String` with extra steps.
/// Configuration is the opposite: constructed, never matched, and certain to
/// grow.
public enum LedgerError: Error, Sendable, Equatable {

    /// No conversation with this identifier exists (never created, or deleted).
    case unknownConversation(ConversationID)

    /// The named message is not in the conversation's tree — `respond`,
    /// `regenerate`, `edit`, or a `switchBranch` onto an endpoint that never
    /// existed.
    ///
    /// Worth noting where the *reducer* would land on the same fact: an
    /// `activePathChanged` naming a never-existent endpoint quarantines (§6.6
    /// row 12). Same fact, correct channel per layer — a store verb has a caller
    /// to tell, and an event in a log does not.
    case unknownMessage(MessageID)

    /// The message exists but is the wrong kind of thing to do this to (§6.5's
    /// store-enforced target eligibility): `respond(to:)` and `edit` require a
    /// **user** message, `regenerate` an **assistant** one.
    ///
    /// Carries both roles because the actionable question is "then what should I
    /// have passed?", and both are labelled because they are the same type — a
    /// swap would compile, which is exactly the case the M4 audit's labelling
    /// rule exists for.
    ///
    /// The reducer deliberately accepts other role adjacencies (§6.1): an
    /// assistant-parented generation is the *continuation* shape, and
    /// continuation is v0.2 research (I7, §12), not something v0.1 backs into by
    /// accident. Enforcement is store policy, headroom is wire — the N10
    /// pattern.
    case ineligibleTarget(message: MessageID, expected: Role, found: Role)

    /// A generation is already live in this conversation (§6.5's single-flight).
    ///
    /// Throw, don't queue: queuing would hide a product decision inside a
    /// library — should the second send target the leaf the in-flight generation
    /// is about to create? — where surfacing it lets the app disable the send
    /// button, which is what every chat UI does anyway. Cross-conversation
    /// concurrency is unrestricted, and parallel siblings become a v0.2 *policy
    /// relaxation* rather than a migration, since the log already tolerates them.
    case generationInFlight(ConversationID)

    /// The storage backend failed. Nothing was recorded.
    ///
    /// **The payload is prose, and that is the design** (ADR-003 rule 1): GRDB
    /// must never leak — not in a signature, not in a thrown type, not by
    /// re-export — and wrapping the underlying error would leak it through the
    /// back door, pinning the §12 cut line to raw sqlite3 in the process. What a
    /// caller can *do* about a storage failure does not vary by which storage
    /// failed.
    ///
    /// Follows ``GenerationError``'s precedent: the type is `Equatable` because
    /// tests and callers benefit, and the standing rule (ADR-001) applies —
    /// **assert the case, never the wording.**
    case persistenceFailure(description: String)
}

extension LedgerError {

    /// Wraps a backend failure so its type stops here.
    ///
    /// Named for the operation rather than the case so a call site reads as the
    /// boundary crossing it is. Deliberately *not* used for `CancellationError`,
    /// which crosses the throw channel as itself (see the type note).
    static func wrapping(_ error: any Error) -> Self {
        .persistenceFailure(description: String(describing: error))
    }
}

extension LedgerError: CustomStringConvertible {

    /// One log line.
    ///
    /// **Non-contractual** (ADR-001's standing rule, and `GenerationError`'s
    /// precedent): the wording may change in any release. Assert on cases and
    /// their payloads; never on this string.
    public var description: String {
        switch self {
        case .unknownConversation(let id):
            "unknown conversation \(id)"
        case .unknownMessage(let id):
            "unknown message \(id)"
        case .ineligibleTarget(let message, let expected, let found):
            "ineligible target \(message): expected a \(expected.rawValue) message, found \(found.rawValue)"
        case .generationInFlight(let id):
            "a generation is already in flight in conversation \(id)"
        case .persistenceFailure(let description):
            "persistence failure: \(description)"
        }
    }
}
