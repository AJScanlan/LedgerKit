/// Why the reducer skipped an event (SPEC §6.6, I2).
///
/// **This enum is §6.6's "single inventory," in code.** The spec's table is
/// normative and this type mirrors it row for row, which buys three things a
/// bare `String` reason could not:
///
/// - The inventory is **compiler-checked**. Rendering prose is one exhaustive
///   switch, so a new condition cannot be added without confronting every place
///   that reports one.
/// - Hostile fixtures (SPEC §10.2) assert **cases, not sentences**. ADR-001
///   declares the diagnostic strings non-contractual and free to reword; tests
///   that matched on prose would have quietly frozen them (Hyrum's Law).
/// - Cases carry the offending identifier, so a diagnostic can say *which*
///   parent was unknown without string interpolation at the throw site.
///
/// Several rows share a case on purpose — an unknown parent is row 6 for a user
/// message and row 8 for a generation, and `messageIDAlreadyUsed` covers all
/// three of I7's once-only sites (rows 6, 8, 11). That is the rule being one
/// rule rather than three coincidences, so the cases are named after the
/// *condition*, and the row numbers live in the doc comments.
///
/// Note there is deliberately **no case for row 3**: an undecodable outcome
/// inside a decodable `generationEnded` does not quarantine at all — it lands as
/// `.failed(.unrecognized(…))` (SPEC §6.1, the tolerant-terminal rule).
///
/// `Codable` because snapshots persist accumulated diagnostics (§9, or P3
/// fails). The conformance is synthesized rather than hand-written, which is
/// safe precisely because the snapshot format is discard-on-mismatch and
/// disposable — the opposite of `LedgerEvent.Payload`, whose encoding is
/// permanent and therefore hand-pinned (ADR-001).
///
/// `Hashable` so residue can be grouped or deduplicated — a log with a 10k-row
/// cascade is more legible as counts per reason than as a flat list.
public enum QuarantineReason: Sendable, Hashable, Codable {

    // MARK: Decode-level (rows 1–2)

    /// Row 1 — the row's contents were unreadable and no event identity
    /// survived. The only reason, besides a sequence gap, that leaves
    /// `QuarantinedEvent.eventID` nil.
    case undecodableEnvelope

    /// Row 2 — a payload discriminator this version does not know, i.e. written
    /// by a newer LedgerKit. Carries the tag where it was legible. The
    /// forward-compatibility row: the conversation loads degraded, never fails.
    case unknownPayloadKind(String?)

    // MARK: Stream integrity (rows 4–5)

    /// Row 4 — the envelope names a different stream than the one it was loaded
    /// from. Cross-stream contamination is malformed by definition; this is what
    /// `conversationID`'s deliberate column/blob duplication exists to catch.
    case foreignConversation(found: ConversationID)

    /// Row 5 — an event arrived before `conversationCreated`.
    case beforeGenesis

    /// Row 5 — a second `conversationCreated`. Genesis is sequence 1, once.
    case duplicateGenesis

    // MARK: Tree integrity (rows 6–8, 11)

    /// Rows 6, 8 — the named parent is not in the tree. Every non-nil parent
    /// must exist *and* precede its child in sequence order (I6).
    case unknownParent(MessageID)

    /// Rows 6, 8, 11 — I7's once-only rule: this `MessageID` already names a
    /// node. Applies at all three sites that introduce one, because an
    /// append-only log must never let a later event rewrite an existing node.
    case messageIDAlreadyUsed(MessageID)

    /// Row 7 — a bare `userMessageAppended(parent: nil)` after the first. The
    /// "new topic ≠ new branch" guard: an accidental nil parent must not
    /// silently become a hidden root-level branch (I6).
    case additionalRootMessage(MessageID)

    /// Row 11 — `messageEdited` naming a message the tree does not hold.
    case unknownEditTarget(MessageID)

    /// Row 11 — `messageEdited` naming an assistant message. Editing one would
    /// manufacture user-authored assistant content and corrupt the audit trail;
    /// rewriting what the assistant said is what Regenerate is for (§6.1).
    case editTargetNotUser(MessageID)

    // MARK: Generation scope (rows 8–10)

    /// Row 8 — this `GenerationID` has already been used. Reuse stays invalid
    /// after termination: the binding is permanent, not merely current.
    case generationIDAlreadyUsed(GenerationID)

    /// Row 9 — a delta or tool record naming a generation that never started.
    case unknownGeneration(GenerationID)

    /// Row 9 — a delta or tool record after the generation's terminal. A
    /// terminal message's content *and* audit trail are immutable (I4).
    case generationAlreadyTerminated(GenerationID)

    /// Row 10 — a second `generationEnded` for one generation (I3). A cancel
    /// racing a natural terminal lands here, benignly: first append wins.
    case duplicateTerminal(GenerationID)

    // MARK: Path (row 12)

    /// Row 12 — `activePathChanged` naming an endpoint that never existed.
    /// Distinct from *clamping*, which handles a path invalidated by a later
    /// quarantine: a never-valid endpoint is malformed, not stale.
    case unknownPathEndpoint(MessageID)

    // MARK: Absence, not an event (§6.1)

    /// Not a table row — a hole in the sequence run. One diagnostic per
    /// *contiguous* gap, so a 10k-row hole costs one diagnostic rather than
    /// 10k. A healthy log has none: deletion is conversation-level, so a gap
    /// means partial restore or external tampering. If the hole swallowed a
    /// terminal, I5 does what it always does and the generation reduces open —
    /// correct, because you truly don't know how it ended.
    case sequenceGap(missing: ClosedRange<Int64>)
}

extension QuarantineReason: CustomStringConvertible {

    /// Log-facing prose. Non-contractual by ADR-001 — reword freely; assert on
    /// the cases instead.
    public var description: String {
        switch self {
        case .undecodableEnvelope:
            "row undecodable; no event identity recoverable"
        case .unknownPayloadKind(let kind):
            "unknown payload kind: \(kind ?? "<unreadable>")"
        case .foreignConversation(let found):
            "envelope names conversation \(found), which is not the stream it was loaded from"
        case .beforeGenesis:
            "event precedes conversationCreated"
        case .duplicateGenesis:
            "second conversationCreated"
        case .unknownParent(let parent):
            "unknown parent: \(parent)"
        case .messageIDAlreadyUsed(let message):
            "message ID already in use: \(message)"
        case .additionalRootMessage(let message):
            "bare nil-parent append after the first: \(message)"
        case .unknownEditTarget(let message):
            "edit names an unknown message: \(message)"
        case .editTargetNotUser(let message):
            "edit names an assistant message: \(message)"
        case .generationIDAlreadyUsed(let generation):
            "generation ID already in use: \(generation)"
        case .unknownGeneration(let generation):
            "unknown generation: \(generation)"
        case .generationAlreadyTerminated(let generation):
            "generation already terminated: \(generation)"
        case .duplicateTerminal(let generation):
            "second terminal for generation: \(generation)"
        case .unknownPathEndpoint(let endpoint):
            "active path endpoint never existed: \(endpoint)"
        case .sequenceGap(let missing):
            missing.lowerBound == missing.upperBound
                ? "missing sequence \(missing.lowerBound)"
                : "missing sequences \(missing.lowerBound)–\(missing.upperBound)"
        }
    }
}
