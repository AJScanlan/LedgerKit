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

    @Test("DoD-1: the interrupted partial survives as its own branch, beside the regeneration")
    func interruptedPartialSurvivesAsBranch() {
        // The demo's hero shape, asserted at the reducer where it actually
        // happens: no recovery pass, no dirty flag — the second generation is
        // just another child of the same user message, and the first one's
        // missing terminal speaks for itself.
        let conversation = Corpus.regenerateAfterInterruption.log.reduced()

        #expect(conversation.messages[Fix.userA]?.children == [Fix.assistantA, Fix.assistantB])
        #expect(conversation.messages[Fix.assistantA]?.state == .interrupted(partial: "A valley fol"))
        #expect(
            conversation.messages[Fix.assistantB]?.state
                == .complete(Content(text: "A valley fold brings the paper down."))
        )
        #expect(conversation.activePath == [Fix.userA, Fix.assistantB], "the visible thread is the regeneration")
        #expect(
            conversation.messages.siblings(of: Fix.assistantB).map(\.id) == [Fix.assistantA],
            "the branch switcher can reach the abandoned partial"
        )
    }

    @Test("I5 through absence: a gap that swallowed the terminal still interrupts")
    func gapSwallowedTerminalInterrupts() {
        // I5 says "no terminal event anywhere in the log", not "the log ends
        // here" — so a hole in the middle produces the same honest answer as
        // process death, and reduction continues past it.
        let fixture = Corpus.gapSwallowedTerminal
        #expect(fixture.log.folded().messages[Fix.assistantA]?.state == .open(partial: "half an answer"))
        #expect(fixture.log.reduced().messages[Fix.assistantA]?.state == .interrupted(partial: "half an answer"))
        #expect(fixture.log.reduced().title == "after the hole", "reduction continued past the hole")
    }

    @Test("I1: the golden fixtures' orderings are pinned to literals too")
    func goldenOrderings() {
        let multi = Corpus.multiTurn.log.folded()
        #expect(multi.rootChildren == [Fix.userA])
        #expect(multi.activePath == [Fix.userA, Fix.assistantA, Fix.userB, Fix.assistantB, Fix.userC])

        let edit = Corpus.editBranch.log.folded()
        #expect(edit.messages[Fix.assistantA]?.children == [Fix.userB, Fix.edited])
        #expect(edit.activePath == [Fix.userA, Fix.assistantA, Fix.edited])

        let root = Corpus.rootEdit.log.folded()
        #expect(root.rootChildren == [Fix.userA, Fix.edited], "the virtual root has two children")
        #expect(root.activePath == [Fix.edited])

        let tools = Corpus.toolsAndMetadata.log.folded()
        #expect(tools.messages[Fix.assistantA]?.toolRecords.map(\.name) == ["search", "fetch"])
        #expect(tools.instructions == "You are an origami tutor.")
        #expect(tools.title == nil, "titleChanged(nil) clears")
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
