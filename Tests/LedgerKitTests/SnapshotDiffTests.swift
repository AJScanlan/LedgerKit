import Foundation
import Testing
@testable import LedgerKit

// M6 Phase 1: the pure differ (D34), tier 1 — no Foundation Models anywhere in
// this file or in what it tests, so it runs in every `swift test` on any Mac.
//
// The organizing claim is one line, and every test below is either an instance
// of it or a probe of where it stops holding:
//
//     .appended(d)  ⇒  previous.text + d == current.text
//
// That is the whole contract between a cumulative stream and an append-only
// ledger. `everyEmittedDeltaIsExact` asserts it over every pair this file can
// build, well-behaved and hostile alike, which is what makes "the driver never
// emits a wrong delta" a property rather than a hope.

@Suite("Session — the snapshot differ")
struct SnapshotDiffTests {

    // MARK: - Fixtures

    private func snapshot(_ segments: (String, String)...) -> StreamSnapshot {
        StreamSnapshot(segments: segments.map { StreamSnapshot.Segment(id: $0.0, text: $0.1) })
    }

    /// Every pair this suite exercises, well-behaved and hostile, so the
    /// exactness invariant can sweep the hostile half too — a differ that
    /// emitted a delta *there* is the failure mode that matters most, and a
    /// sweep over only well-behaved input could never see it.
    private var allPairs: [(previous: StreamSnapshot, current: StreamSnapshot)] {
        [
            // Well-behaved.
            (snapshot(), snapshot(("a", "hello"))),
            (snapshot(("a", "hello")), snapshot(("a", "hello world"))),
            (snapshot(("a", "hello")), snapshot(("a", "hello"))),
            (snapshot(("a", "hello")), snapshot(("a", "hello"), ("b", "!"))),
            (snapshot(("a", "hello")), snapshot(("a", "hello there"), ("b", "!"))),
            (snapshot(("a", "hello"), ("b", "")), snapshot(("a", "hello"), ("b", "world"))),
            (snapshot(), snapshot()),
            // Hostile.
            (snapshot(("a", "abc")), snapshot(("a", "abd"))),
            (snapshot(("a", "abc")), snapshot(("a", "ab"))),
            (snapshot(("a", "a"), ("b", "b")), snapshot(("a", "a"))),
            (snapshot(("a", "a"), ("b", "b")), snapshot(("b", "b"), ("a", "a"))),
            (snapshot(("a", "a")), snapshot(("c", "a"))),
            (snapshot(("a", "a"), ("b", "b")), snapshot(("a", "aX"), ("b", "b"))),
            (StreamSnapshot.flat("ab"), snapshot(("a", "abc"))),
        ]
    }

    // MARK: - The shapes that are appends

    @Test("a segment growing yields its suffix")
    func growthWithinASegment() {
        #expect(delta(from: snapshot(("a", "hello")), to: snapshot(("a", "hello world"))) == .appended(" world"))
    }

    @Test("the first snapshot of a stream is entirely new text")
    func openingSnapshot() {
        #expect(delta(from: StreamSnapshot(), to: snapshot(("a", "hello"))) == .appended("hello"))
    }

    /// A repeat is legal and must not read as a violation — providers re-emit,
    /// and refusing here would fail a generation over a no-op.
    @Test("an unchanged snapshot appends nothing")
    func repeatedSnapshot() {
        #expect(delta(from: snapshot(("a", "hello")), to: snapshot(("a", "hello"))) == .appended(""))
    }

    @Test("a newly opened segment contributes its whole text")
    func newSegment() {
        #expect(delta(from: snapshot(("a", "hi")), to: snapshot(("a", "hi"), ("b", " there"))) == .appended(" there"))
    }

    /// The last segment may grow *and* a new one open in the same step: both
    /// land after everything the predecessor held, so the concatenation is still
    /// an append.
    @Test("the tail may grow while a segment opens beside it")
    func tailGrowthWithANewSegment() {
        let previous = snapshot(("a", "one"), ("b", "two"))
        let current = snapshot(("a", "one"), ("b", "two!"), ("c", "three"))
        #expect(delta(from: previous, to: current) == .appended("!three"))
    }

    /// An empty segment has nothing for later text to jump ahead of, so growth
    /// in the segment before it is still an append — the boundary case of the
    /// `interiorGrowth` rule, and the one a naive "only the last segment may
    /// grow" check would refuse.
    @Test("growth ahead of an empty segment is still an append")
    func growthAheadOfAnEmptySegment() {
        let previous = snapshot(("a", "one"), ("b", ""))
        let current = snapshot(("a", "one!"), ("b", ""))
        #expect(delta(from: previous, to: current) == .appended("!"))
    }

    // MARK: - The shapes that are not

    /// The `replaceTextSegment` shape (§7.3, rev 7): legal provider behaviour
    /// this version does not model, so it fails loudly rather than corrupting.
    @Test("a revised segment is refused")
    func revisedSegment() {
        #expect(delta(from: snapshot(("a", "abc")), to: snapshot(("a", "abd")))
            == .nonPrefix(.segmentRevised(id: "a")))
    }

    @Test("a shortened segment is refused")
    func shortenedSegment() {
        #expect(delta(from: snapshot(("a", "abc")), to: snapshot(("a", "ab")))
            == .nonPrefix(.segmentRevised(id: "a")))
    }

    @Test("a dropped segment is refused")
    func droppedSegment() {
        #expect(delta(from: snapshot(("a", "a"), ("b", "b")), to: snapshot(("a", "a")))
            == .nonPrefix(.segmentDropped(id: "b")))
    }

    @Test("reordered segments are refused")
    func reorderedSegments() {
        #expect(delta(from: snapshot(("a", "a"), ("b", "b")), to: snapshot(("b", "b"), ("a", "a")))
            == .nonPrefix(.segmentsReordered(expected: "a", found: "b")))
    }

    /// Renaming is caught by the same check as reordering: identity is compared
    /// before text, because text from two differently-named segments is not
    /// comparable in the first place.
    @Test("a renamed segment is refused before its text is considered")
    func renamedSegment() {
        #expect(delta(from: snapshot(("a", "abc")), to: snapshot(("c", "abcd")))
            == .nonPrefix(.segmentsReordered(expected: "a", found: "c")))
    }

    /// **Per-segment this is a legal append; in the ledger it is not.** Message
    /// content is the concatenation of `deltaAppended` rows in order, so text
    /// added to an earlier segment would have to be inserted mid-string.
    @Test("growth in an interior segment is refused")
    func interiorGrowth() {
        #expect(delta(from: snapshot(("a", "a"), ("b", "b")), to: snapshot(("a", "aX"), ("b", "b")))
            == .nonPrefix(.interiorGrowth(id: "a")))
    }

    /// Mixing the flat fallback with segment-aware extraction mid-generation
    /// reads as a segment being replaced — correctly, since the two views
    /// disagree about what the segment is called.
    @Test("switching between flat and segment-aware mid-stream is refused")
    func mixedModes() {
        #expect(delta(from: .flat("ab"), to: snapshot(("a", "abc")))
            == .nonPrefix(.segmentsReordered(expected: StreamSnapshot.flatSegmentID, found: "a")))
    }

    // MARK: - Flat mode

    /// With one segment the rules collapse to plain prefix-diffing, which is
    /// exactly what the flat fallback is (§7.3).
    @Test("flat snapshots prefix-diff")
    func flatMode() {
        #expect(delta(from: .flat("A valley "), to: .flat("A valley fold")) == .appended("fold"))
        #expect(delta(from: .flat("A valley "), to: .flat("A mountain "))
            == .nonPrefix(.segmentRevised(id: StreamSnapshot.flatSegmentID)))
    }

    // MARK: - Unicode

    /// **The reason the comparison is over UTF-8 and not `Character`s.** A
    /// provider emitting `"e"` and then a combining acute is appending; a
    /// grapheme-wise `hasPrefix` sees `"e"` against the single cluster `"é"`,
    /// concludes the segment was revised, and fails a well-behaved generation.
    @Test("a combining mark arriving after its base character is an append")
    func combiningMarkIsAnAppend() {
        let combining = "\u{301}"
        let result = delta(from: .flat("cafe"), to: .flat("cafe" + combining))

        #expect(result == .appended(combining))
        // And the exactness that matters downstream: the ledger reassembles the
        // bytes the provider sent, not a normalization of them.
        guard case .appended(let text) = result else { return }
        #expect("cafe" + text == "cafe" + combining)
    }

    @Test("multi-byte text diffs on scalar boundaries")
    func multiByteText() {
        #expect(delta(from: .flat("お"), to: .flat("おりがみ")) == .appended("りがみ"))
    }

    // MARK: - Properties

    /// **The store-side half of §7.3's round trip, proved before the framework
    /// is in the loop.** Exhaustive over every append-only shape a stream can
    /// take in six steps — 126 sequences — which beats randomization on the axes
    /// that matter here: no seed, no flake, and a failure that reproduces by
    /// re-running (§10, "exhaustive, not randomized").
    @Test("over every well-behaved stream, the deltas concatenate to the final text")
    func deltasReconstructTheStream() {
        for steps in Self.allStreamShapes(upTo: 6) {
            let stream = Self.snapshots(for: steps)
            var recovered = ""
            var refused = false

            for (previous, current) in zip(stream, stream.dropFirst()) {
                guard case .appended(let text) = delta(from: previous, to: current) else {
                    Issue.record("an append-only stream was refused: \(steps)")
                    refused = true
                    break
                }
                recovered += text
            }

            if !refused {
                #expect(recovered == stream.last?.text, "shape: \(steps)")
            }
        }
    }

    /// **No wrong delta, ever.** Swept over the hostile pairs too, where it is
    /// the assertion that actually bites: a differ that emitted *something* for
    /// a revised or reordered snapshot would corrupt a transcript, which §7.3
    /// says is worse than failing the generation outright.
    @Test("every emitted delta reconstructs its snapshot exactly")
    func everyEmittedDeltaIsExact() {
        for pair in allPairs {
            guard case .appended(let text) = delta(from: pair.previous, to: pair.current) else { continue }
            #expect(
                pair.previous.text + text == pair.current.text,
                "delta \(text.debugDescription) does not carry \(pair.previous.text.debugDescription) to \(pair.current.text.debugDescription)"
            )
        }
    }

    /// The same invariant over the exhaustive sweep, stated per step rather than
    /// per stream — a run whose deltas concatenate correctly overall could still
    /// have mis-attributed text between two adjacent steps, and the store writes
    /// one row per step.
    @Test("every step of every well-behaved stream is exact")
    func everyStepIsExact() {
        for steps in Self.allStreamShapes(upTo: 5) {
            let stream = Self.snapshots(for: steps)
            for (previous, current) in zip(stream, stream.dropFirst()) {
                guard case .appended(let text) = delta(from: previous, to: current) else { continue }
                #expect(previous.text + text == current.text, "shape: \(steps)")
            }
        }
    }

    // MARK: - The generator

    /// One thing a provider can do between snapshots, restricted to the
    /// append-only half: grow the open segment, or open a new one.
    enum StreamStep: Equatable, CustomStringConvertible {
        case grow(String)
        case open(String)

        var description: String {
            switch self {
            case .grow(let text): "grow(\(text))"
            case .open(let text): "open(\(text))"
            }
        }
    }

    /// Every sequence of steps up to `length`, exhaustively — 2ⁿ per length, 126
    /// in total at six.
    static func allStreamShapes(upTo length: Int) -> [[StreamStep]] {
        var shapes: [[StreamStep]] = []
        for count in 1...length {
            for pattern in 0..<(1 << count) {
                shapes.append((0..<count).map { position in
                    // Distinct per position, so a delta landing at the wrong
                    // step is visible rather than absorbed by identical text.
                    let text = "t\(position)"
                    return pattern & (1 << position) == 0 ? .grow(text) : .open(text)
                })
            }
        }
        return shapes
    }

    /// The cumulative snapshots those steps produce — the provider's side of
    /// §7.3, with the framework's accumulation done by hand.
    static func snapshots(for steps: [StreamStep]) -> [StreamSnapshot] {
        var current = StreamSnapshot()
        var stream = [current]
        var opened = 0

        for step in steps {
            switch step {
            case .grow(let text):
                if current.segments.isEmpty {
                    current.segments.append(StreamSnapshot.Segment(id: "s0", text: text))
                    opened = 1
                } else {
                    current.segments[current.segments.count - 1].text += text
                }
            case .open(let text):
                current.segments.append(StreamSnapshot.Segment(id: "s\(opened)", text: text))
                opened += 1
            }
            stream.append(current)
        }
        return stream
    }
}
