import Foundation
import Testing
@testable import LedgerKit

// Each corpus fixture's own expectations: the exact residue it produces, and —
// for fixtures rich enough to be worth pinning — the literal orderings that
// catch dictionary-iteration leakage across processes.
//
// Generic predicates that must hold for *every* log live in `CorpusSweepTests`.

@Suite("Corpus — fixture expectations")
struct CorpusTests {

    @Test("every fixture produces exactly the residue the registry pins")
    func residueIsExact() {
        // Exact and ordered, in both dimensions. `hostileRowCoverage` previously
        // asserted `Set.contains` per row, which cannot catch a diagnostic
        // blaming the wrong sequence, a duplicate, or an extra — all of which
        // are §6.6 bugs a developer would read straight past.
        for fixture in Corpus.all {
            #expect(
                fixture.log.folded().residue == fixture.residue,
                "\(fixture.name): \(fixture.summary)"
            )
        }
    }

    @Test("classification carries residue through untouched")
    func residueSurvivesClassification() {
        for fixture in Corpus.all {
            #expect(fixture.log.reduced().residue == fixture.residue, "\(fixture.name)")
        }
    }

    @Test("a golden fixture is one that reduces cleanly — the kinds are not decorative")
    func kindsAgreeWithResidue() {
        for fixture in Corpus.all {
            switch fixture.kind {
            case .golden:
                #expect(fixture.residue.isEmpty, "\(fixture.name) is golden but pins residue")
            case .hostile:
                #expect(!fixture.residue.isEmpty, "\(fixture.name) is hostile but pins no residue")
            }
        }
    }

    @Test("I1: rich's orderings are pinned to literals, which is what catches hash-seed leakage")
    func richGolden() {
        // Repeating the fold in one process proves nothing — Swift's hasher seed
        // is fixed per process. What catches dictionary-order dependence is a
        // literal captured in one process and re-checked in every later one, so
        // these expectations are deliberately spelled out rather than computed.
        let state = Corpus.rich.log.folded()
        #expect(state.rootChildren == [Fix.userA])
        #expect(state.messages[Fix.userA]?.children == [Fix.assistantA])
        #expect(state.messages[Fix.assistantA]?.children == [Fix.userB, Fix.edited])
        #expect(state.messages[Fix.edited]?.children == [Fix.assistantB])
        #expect(state.activePath == [Fix.userA, Fix.assistantA, Fix.edited, Fix.assistantB])
        #expect(state.messages[Fix.assistantA]?.state == .complete(Content(text: "one two")))
        #expect(state.messages[Fix.assistantB]?.state == .open(partial: "partial"))
        #expect(state.title == "Origami, revised")
    }

    @Test("hostile: reduction survives every row it violates, and the survivors are intact")
    func hostileSurvivors() {
        // I2's containment posture, stated positively: the residue above says
        // what was skipped, and this says the conversation is still there.
        let state = Corpus.hostile.log.folded()
        #expect(state.hasGenesis)
        #expect(state.title == "end", "reduction continued past the gap to the last valid title")
        #expect(state.rootChildren == [Fix.userA], "row 7 kept the second root out of the tree")
        #expect(state.messages[Fix.assistantA] == nil, "the cascade's start never created a node")
        #expect(
            state.messages[Fix.assistantB]?.state == .cancelled(partial: "real"),
            "the late delta and second terminal left the real generation untouched"
        )
    }
}
