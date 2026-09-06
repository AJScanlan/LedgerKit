import Foundation

// Snapshot→delta diffing (SPEC §7.3), as a pure component the driver merely
// feeds (M6-PLAN D34).
//
// FM streams *cumulative snapshots*; the ledger stores *append-only deltas*. The
// subtraction between those two facts is where transcript-correctness risk
// lives, so it must be testable on any Mac — but `Transcript.Entry` is 27-only.
// The resolution is a seam one notch below the driver: everything here is over
// LedgerKit-owned values, and the 27-gated driver's whole diffing job is
// *extraction*.
//
// This is not the "internal imitation" M3's D11 retired. Nothing here imitates a
// protocol conformance; it factors pure logic out of platform types, the same
// move as `Understudy`'s platform-agnostic engine.

/// One cumulative snapshot from a response stream, reduced to what the ledger
/// needs: ordered runs of text (SPEC §7.3).
///
/// ⚠️ **Not `Store`'s `Snapshot`**, which is a persisted `FoldedState`
/// checkpoint. Two layers, two unrelated things a reader would call a snapshot;
/// the `Stream` prefix is here so the collision cannot be made silently.
///
/// The shape is Apple's, one level down: `Transcript.TextSegment` is
/// `{ id: String, content: String }`, so extraction is a `map` and this type
/// invents nothing. Segment-aware is *preferred* over the flat string because
/// the flat view erases the identities — see ``flat(_:)``.
struct StreamSnapshot: Equatable, Sendable {

    /// One addressable run of text; `id` is the provider's `segmentID`.
    struct Segment: Equatable, Sendable {
        var id: String
        var text: String

        init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// The identity used by ``flat(_:)``. Not a valid provider segment ID, which
    /// is the point: a flat snapshot must never appear to line up with a
    /// segment-aware one.
    static let flatSegmentID = ""

    var segments: [Segment]

    init(segments: [Segment] = []) {
        self.segments = segments
    }

    /// The flat-content fallback: one anonymous segment (§7.3).
    ///
    /// For where `transcriptEntries` is unavailable. Correct but **strictly
    /// weaker**: with one segment the rules below collapse to plain
    /// prefix-diffing, which cannot tell "the provider revised its only segment"
    /// from "the provider is emitting different text", because the flat view
    /// erased the identity that would have said so. Consecutive snapshots in one
    /// generation must use one mode throughout — mixing them reads as a segment
    /// being replaced, and is correctly refused.
    static func flat(_ text: String) -> Self {
        Self(segments: [Segment(id: flatSegmentID, text: text)])
    }

    /// The whole snapshot's text in segment order — what a flat reader sees.
    var text: String {
        segments.map(\.text).joined()
    }
}

/// What one snapshot added to its predecessor (SPEC §7.3).
enum SnapshotDelta: Equatable, Sendable {

    /// The new text, in segment order. Empty when a snapshot repeats itself,
    /// which is legal and must not be mistaken for a violation.
    case appended(String)

    /// The snapshot does not extend its predecessor, so **no honest delta
    /// exists**.
    ///
    /// The driver's response is to fail the generation loudly —
    /// `unrecognized("driver: non-prefix snapshot")` — and never to emit a
    /// reconstruction: a wrong transcript is worse than a dead one. Rev 7 moved
    /// this from a can't-happen assertion to a real path, because
    /// `replaceTextSegment` makes prefix-stability provider *behaviour* rather
    /// than an API guarantee.
    case nonPrefix(Reason)

    /// Why the snapshot could not be expressed as an append.
    ///
    /// The driver treats all four identically; they are distinguished because a
    /// test asserting *which* violation it caught is a stronger test than one
    /// asserting merely that something was refused, and because these are the
    /// shapes to quote if a real provider ever trips one. **None has yet:** M6
    /// observed zero non-prefix snapshots across 412 snapshots of a real
    /// generation (§7.3 consequence 4), which is why these cases are reachable
    /// only from unit tests — and why they stay, since the API still permits
    /// the revision the observation merely failed to produce.
    enum Reason: Equatable, Sendable {
        /// A segment's text changed rather than grew — the `replaceTextSegment`
        /// shape exactly.
        case segmentRevised(id: String)
        /// A segment the predecessor carried is gone.
        case segmentDropped(id: String)
        /// Identities no longer line up in order, so nothing can be matched.
        case segmentsReordered(expected: String, found: String)
        /// A segment grew while a *later* segment already held text.
        ///
        /// Per-segment this is a legal append; in the ledger it is not. Message
        /// content is the concatenation of `deltaAppended` rows in event order,
        /// so text added to an earlier segment would have to be *inserted*
        /// mid-string, which an append-only log cannot express. The flat view
        /// reaches the same verdict by a shorter route — the concatenation is
        /// simply not a prefix extension.
        case interiorGrowth(id: String)
    }
}

/// Diffs consecutive cumulative snapshots into the suffix `deltaAppended`
/// carries (SPEC §7.3).
///
/// Pure and total: every input pair yields a verdict, and none of them traps.
/// The four conditions it enforces are exactly the ones under which
/// "concatenate the per-segment suffixes" is a *faithful* description of what
/// the provider did — identity, order, per-segment growth, and growth confined
/// to the tail.
///
/// Cost is O(text) per call, so a generation is quadratic in its own length. At
/// the sizes involved — a long response is tens of KB against a few hundred
/// snapshots — that is nothing, and the alternative (carrying byte offsets
/// across calls) would trade purity for it.
func delta(from previous: StreamSnapshot, to current: StreamSnapshot) -> SnapshotDelta {
    guard current.segments.count >= previous.segments.count else {
        return .nonPrefix(.segmentDropped(id: previous.segments[current.segments.count].id))
    }

    // Per-segment growth, in place, with identity checked first: a differing ID
    // means the two snapshots are not describing the same stream, and comparing
    // their text would be comparing unrelated things.
    var suffixes: [String] = []
    suffixes.reserveCapacity(current.segments.count)
    for (index, old) in previous.segments.enumerated() {
        let new = current.segments[index]
        guard new.id == old.id else {
            return .nonPrefix(.segmentsReordered(expected: old.id, found: new.id))
        }
        guard let grown = new.text.suffix(extending: old.text) else {
            return .nonPrefix(.segmentRevised(id: old.id))
        }
        suffixes.append(grown)
    }

    // Growth must be confined to the tail — see `interiorGrowth`. Only segments
    // *before* the last one that already held text are constrained: an empty
    // segment has nothing for new text to jump ahead of.
    if let lastWithText = previous.segments.lastIndex(where: { !$0.text.isEmpty }) {
        for index in 0..<lastWithText where !suffixes[index].isEmpty {
            return .nonPrefix(.interiorGrowth(id: previous.segments[index].id))
        }
    }

    // Segments opened by this snapshot contribute their whole text; they sit
    // after everything the predecessor had, so they are always an append.
    let opened = current.segments[previous.segments.count...].map(\.text)
    return .appended(suffixes.joined() + opened.joined())
}

private extension String {

    /// What this string adds to `prefix`, or `nil` if it does not extend it.
    ///
    /// **Compared as UTF-8 rather than as `Character`s, which is a correctness
    /// requirement and not a micro-optimization.** `hasPrefix` compares grapheme
    /// clusters under canonical equivalence, so a stream that emits `"e"` and
    /// then a combining acute would read as having *revised* its segment — `"e"`
    /// is not a grapheme prefix of `"é"`, because the accented form is a single
    /// cluster — and the driver would fail a perfectly well-behaved generation.
    /// Bytes see the append that actually happened.
    ///
    /// Bytes are also what the ledger stores, so `prefix + suffix == self` holds
    /// *exactly* rather than up to normalization — which is what makes §7.3's
    /// round-trip property (script fragments in, `deltaAppended` rows out) an
    /// equality rather than an approximation.
    func suffix(extending prefix: String) -> String? {
        guard utf8.starts(with: prefix.utf8) else { return nil }
        // The slice begins on a scalar boundary because `prefix` is itself a
        // valid `String`, so this decode cannot lose or replace anything.
        return String(decoding: utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }
}
