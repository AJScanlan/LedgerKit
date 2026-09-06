import Foundation
import Testing
@testable import LedgerKit

// M5 Phase 1: the actor as a correct single-conversation machine — the
// fold-forward cache, the stamping site, and the verbs with no tree or
// generation semantics.
//
// Fixtures come from `Log` (ReducerFixtures.swift) and `StoreFixtures.swift`
// rather than being rebuilt here, so a verb test can assert "these verbs
// produced this log" against the very fixtures the reducer suites fold.

@Suite("Store — lifecycle verbs")
struct StoreLifecycleTests {

    @Test("createConversation writes one genesis and returns the empty conversation")
    func createsAConversation() async throws {
        let fixture = try StoreUnderTest()

        let convo = try await fixture.store.createConversation(title: "Valley folds 101")

        #expect(convo.title == "Valley folds 101")
        #expect(convo.messages == MessageTree())
        #expect(convo.activePath.isEmpty)
        #expect(convo.diagnostics.isEmpty)

        let rows = try await fixture.rows(of: convo.id)
        #expect(rows.count == 1)
        #expect(rows.first == .decoded(LedgerEvent(
            record: LedgerEvent.Record(
                id: EventID(uuid(0x101)),
                conversationID: convo.id,
                timestamp: Log.base.addingTimeInterval(1),
                payload: .conversationCreated(title: "Valley folds 101")
            ),
            sequence: 1
        )))
    }

    @Test("a title is optional at creation")
    func createsWithoutATitle() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        #expect(convo.title == nil)
    }

    @Test("metadata verbs land, and nil clears both (§6.1)")
    func metadataRoundTrips() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation(title: "one")

        try await fixture.store.setInstructions("You are an origami tutor.", in: convo.id)
        try await fixture.store.setTitle("two", in: convo.id)

        var read = try await fixture.store.conversation(convo.id)
        #expect(read.title == "two")
        #expect(read.instructions == "You are an origami tutor.")

        // Last write wins, and nil is a value rather than an omission — which is
        // what makes these two verbs idempotent under replay (§6.6's ordering
        // note).
        try await fixture.store.setInstructions(nil, in: convo.id)
        try await fixture.store.setTitle(nil, in: convo.id)

        read = try await fixture.store.conversation(convo.id)
        #expect(read.title == nil)
        #expect(read.instructions == nil)
    }

    @Test("conversations are separate streams")
    func conversationsAreIndependent() async throws {
        let fixture = try StoreUnderTest()

        let first = try await fixture.store.createConversation(title: "first")
        let second = try await fixture.store.createConversation(title: "second")

        #expect(first.id != second.id)
        #expect(try await fixture.rows(of: first.id).count == 1)
        #expect(try await fixture.rows(of: second.id).count == 1)
        #expect(try await fixture.store.conversation(first.id).title == "first")
        #expect(try await fixture.store.conversation(second.id).title == "second")
    }

    /// The two-channel contract's throw side, at the only verbs that have one
    /// yet: `try` guards *did it start*, and a verb that failed to start left the
    /// log untouched.
    @Test("verbs naming an unknown conversation throw, and write nothing")
    func unknownConversationThrows() async throws {
        let fixture = try StoreUnderTest()
        let ghost = Fix.foreign

        await #expect(throws: LedgerError.unknownConversation(ghost)) {
            try await fixture.store.conversation(ghost)
        }
        await #expect(throws: LedgerError.unknownConversation(ghost)) {
            try await fixture.store.setTitle("x", in: ghost)
        }
        await #expect(throws: LedgerError.unknownConversation(ghost)) {
            try await fixture.store.setInstructions("x", in: ghost)
        }

        #expect(try await fixture.rows(of: ghost).isEmpty)
    }

    /// A log whose genesis quarantined reads as *unknown*, which is the right
    /// answer for the right reason: every subsequent append to it would
    /// quarantine under §6.6 row 5, so there is nothing a caller could usefully
    /// do with it.
    ///
    /// Seeded through ``PrewrittenStore`` rather than through the seam, because
    /// since D44 the write boundary **refuses** to produce this shape — that
    /// refusal is `WriteBoundaryTests`' subject, and this test's subject is what
    /// the read side does with such a log when it arrives by some other route: a
    /// partial restore, tampering, or a database written before the guard existed.
    @Test("a conversation with no valid genesis is unknown")
    func genesislessLogIsUnknown() async throws {
        var orphan = Log()
        orphan.append(.titleChanged("no genesis here"))

        let fixture = try StoreUnderTest(over: PrewrittenStore(orphan))

        await #expect(throws: LedgerError.unknownConversation(orphan.conversation)) {
            try await fixture.store.conversation(orphan.conversation)
        }
    }

    /// Guardrail 4 through a verb rather than through `init` — ADR-003 rule 1
    /// holds at every crossing, not just the first.
    @Test("a backend failure surfaces as LedgerError, never the backend's type")
    func backendFailuresAreWrapped() async throws {
        let store = ConversationStore(
            persistence: FailingStore(),
            identifiers: ScriptedIdentifiers(),
            now: SteppingClock().now
        )

        do {
            _ = try await store.createConversation()
            Issue.record("expected the append to fail")
        } catch let error as LedgerError {
            guard case .persistenceFailure = error else {
                Issue.record("expected .persistenceFailure, got \(error)")
                return
            }
        }
    }
}

@Suite("Store — the stamping site")
struct StoreStampingTests {

    /// **The Phase 1 gate item.** Under injection (D27) the store mints exactly
    /// what a hand-written `Log` contains — same identifiers, same timestamps,
    /// same payloads, same order. Comparing loaded rows rather than the records
    /// as written means the claim covers the round trip through SQLite too, and
    /// `WireJSON`'s `sortedKeys` makes value identity and byte identity the same
    /// statement here.
    @Test("lifecycle verbs write exactly the hand-written fixture")
    func verbsMatchAFixture() async throws {
        let fixture = try StoreUnderTest()

        let convo = try await fixture.store.createConversation(title: "Valley folds 101")
        try await fixture.store.setInstructions("You are an origami tutor.", in: convo.id)
        try await fixture.store.setTitle("Mountain folds 101", in: convo.id)

        var expected = Log()
        expected.append(.conversationCreated(title: "Valley folds 101"))
        expected.append(.instructionsChanged("You are an origami tutor."))
        expected.append(.titleChanged("Mountain folds 101"))

        #expect(convo.id == expected.conversation)
        #expect(try await fixture.rows(of: convo.id) == expected.rows)
        #expect(expected.timestampsAreCanonical)
    }

    /// M4 handoff 1. `append` debug-asserts stamps arrive canonical and must
    /// never repair them — repairing at write time would give every event two
    /// identities depending on whether it had been to disk (ADR-001 R-5). The
    /// assertion is debug-only; this is not.
    ///
    /// The clock is deliberately **off** the millisecond grid: `Log.base` sits on
    /// whole seconds, so a store doing nothing at all would pass a test built on
    /// it.
    ///
    /// And the assertions are against records **as written**, not as read back,
    /// which mutation testing is what proved necessary. Removing the
    /// canonicalization and reading rows from SQLite still yields canonical
    /// timestamps, because the wire formatter rounds on the way out — so the
    /// re-read is repaired and the divergence is invisible from that side. The
    /// bug R-5 names lives precisely in the gap between the two, which is why
    /// the last expectation below compares them.
    @Test("timestamps are canonical at birth, not repaired at write")
    func stampsAreBornCanonical() async throws {
        let offGrid = Date(timeIntervalSince1970: 1_784_979_000.000_456_7)
        let recorder = RecordingStore(try SQLitePersistenceStore(.inMemory))
        let store = ConversationStore(
            persistence: recorder,
            identifiers: ScriptedIdentifiers(),
            now: { offGrid }
        )

        let convo = try await store.createConversation()
        try await store.setTitle("a title", in: convo.id)

        #expect(recorder.written.count == 2)
        for record in recorder.written {
            #expect(WireDate.canonical(record.timestamp) == record.timestamp)
            // Without this the test would pass on a store that never rounded.
            #expect(record.timestamp != offGrid)
        }

        // One identity, not two: the event in memory and the event re-read from
        // disk are the same value (ADR-001 R-5, P1's shape at one field).
        let rows = try await recorder.events(in: convo.id, from: 1)
        let asWritten = recorder.written.enumerated().map { offset, record in
            LoadedEvent.decoded(LedgerEvent(record: record, sequence: Int64(offset + 1)))
        }
        #expect(rows == asWritten)
    }

    /// D27's other half: the *production* generator plugs into the same seam. A
    /// scripted source proves the payloads; this proves the real one is wired.
    @Test("the live identifier generator plugs into the same initializer")
    func liveGeneratorWorks() async throws {
        let backing = try SQLitePersistenceStore(.inMemory)
        let store = ConversationStore(
            persistence: backing,
            identifiers: IDGenerator.live(),
            now: { Date() }
        )

        let convo = try await store.createConversation(title: "live")
        try await store.setTitle("still live", in: convo.id)

        let rows = try await backing.events(in: convo.id, from: 1)
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap(\.eventID)).count == 2)
        #expect(try await store.conversation(convo.id).title == "still live")
    }
}

@Suite("Store — the fold-forward cache")
struct StoreCacheTests {

    /// The M5 standing property, first instance (M5-PLAN §1): a store-written
    /// log re-reduces with **empty diagnostics**, and the cache agrees with that
    /// re-reduction.
    @Test("a verb sequence produces a healthy log the cache agrees with")
    func healthyLog() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation(title: "one")
        try await fixture.store.setInstructions("be brief", in: convo.id)
        try await fixture.store.setTitle("two", in: convo.id)
        try await fixture.store.setInstructions(nil, in: convo.id)
        try await fixture.store.setTitle(nil, in: convo.id)

        let problems = try await healthyLogProblems(
            convo.id,
            in: fixture.store,
            backedBy: fixture.backing
        )
        #expect(problems.isEmpty, "\(problems)")
    }

    /// P1's discipline applied to the actor: the store folds its own appends
    /// forward instead of re-reading, so a store that has *only* re-read must
    /// reach the same answer.
    @Test("fold-forward equals a cold reopen of the same database")
    func foldForwardEqualsColdReopen() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation(title: "one")
        try await fixture.store.setTitle("two", in: convo.id)
        try await fixture.store.setInstructions("be brief", in: convo.id)

        let warm = try await fixture.store.conversation(convo.id)
        let cold = try await fixture.reopened().conversation(convo.id)
        #expect(warm == cold)
    }

    /// Cold load through the snapshot fast-path's degenerate case: no snapshot,
    /// so a full replay. The store adds no reduction path of its own.
    @Test("a store that never wrote a conversation can still read it")
    func coldLoadsAForeignLog() async throws {
        let backing = try SQLitePersistenceStore(.inMemory)
        let seed = Log.withCompletedTurn()
        _ = try await backing.append(seed.records, to: seed.conversation)

        let fixture = try StoreUnderTest(over: backing)
        let read = try await fixture.store.conversation(seed.conversation)

        #expect(read == seed.reduced())
    }

    /// Eviction costs a replay and can never cost correctness — the log is the
    /// truth. Phase 4's `deleteConversation` leans on exactly this.
    @Test("evicting a cached fold costs a replay, not an answer")
    func evictionIsSafe() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation(title: "one")
        try await fixture.store.setTitle("two", in: convo.id)

        let before = try await fixture.store.conversation(convo.id)
        await fixture.store.evict(convo.id)
        let after = try await fixture.store.conversation(convo.id)

        #expect(before == after)
    }
}

// MARK: - Phase 2: tree verbs

/// The ledger-only verbs — no generation semantics, no driver, just §6.4's path
/// rules made executable.
///
/// Every fixture here is *seeded*: the verb that creates a user message arrives
/// at Phase 3, so an edit test necessarily starts from a log someone else wrote.
/// `StoreUnderTest.continuing(_:)` advances the identifier and clock streams past
/// the seed so the store's output stays comparable to a hand-written `Log`.
@Suite("Store — tree verbs")
struct StoreTreeVerbTests {

    /// A conversation with a *non-root* user message, so an edit's replacement
    /// lands under a real parent rather than the virtual root.
    private func threadWithSecondTurn() -> Log {
        var log = Log.withCompletedTurn()
        log.append(.userMessageAppended(message: Fix.userB, content: "And mountain folds?", parent: Fix.assistantA))
        return log
    }

    @Test("edit writes messageEdited + activePathChanged in one transaction")
    func editIsOneTransaction() async throws {
        let seed = threadWithSecondTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)

        let replacement = try await fixture.store.edit(
            Fix.userB,
            content: "And mountain folds, briefly?",
            in: seed.conversation
        )

        #expect(replacement == Fix.edited)
        #expect(fixture.appends.count == 1, "an edit that split into two transactions is a crash away from a stranded half")
        #expect(fixture.appends.first?.map(\.payload) == [
            .messageEdited(original: Fix.userB, replacement: Fix.edited, content: "And mountain folds, briefly?"),
            .activePathChanged(endpoint: Fix.edited),
        ])
    }

    /// §6.4 case 1: the edit moves the visible thread onto the new branch, and
    /// the original survives beside it — unreachable by default, reachable
    /// through a branch switcher. DoD-1's "partial retained as its own branch"
    /// is the same mechanism seen from the generation side.
    @Test("the edit is on the path and the original survives as a sibling")
    func editBranches() async throws {
        let seed = threadWithSecondTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)

        let replacement = try await fixture.store.edit(Fix.userB, content: "shorter", in: seed.conversation)
        let read = try await fixture.store.conversation(seed.conversation)

        #expect(read.activePath == [Fix.userA, Fix.assistantA, replacement])
        #expect(read.messages[replacement]?.parent == Fix.assistantA)
        #expect(read.messages.siblings(of: replacement).map(\.id) == [Fix.userB])
        #expect(read.messages[Fix.userB] != nil, "the original branch is retained, not replaced")
    }

    /// I6's virtual-root case: editing the *first* message yields a root-level
    /// sibling with no special case anywhere. The corpus already pins the
    /// reduced state; this pins that the **store verb produces that very log**,
    /// event for event.
    @Test("editing a root message reproduces the rootEdit corpus fixture exactly")
    func rootEditMatchesTheCorpus() async throws {
        let seed = Log.withUserMessage()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)

        let replacement = try await fixture.store.edit(
            Fix.userA,
            content: "Explain mountain folds",
            in: seed.conversation
        )

        #expect(replacement == Fix.edited)
        #expect(try await fixture.rows(of: seed.conversation) == Corpus.rootEdit.log.rows)
    }

    @Test("editing an assistant message is ineligible, and writes nothing")
    func editRejectsAssistantTargets() async throws {
        let seed = Log.withCompletedTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)

        await #expect(throws: LedgerError.ineligibleTarget(
            message: Fix.assistantA,
            expected: .user,
            found: .assistant
        )) {
            try await fixture.store.edit(Fix.assistantA, content: "forged", in: seed.conversation)
        }

        #expect(fixture.written.isEmpty)
        #expect(try await fixture.rows(of: seed.conversation) == seed.rows)
    }

    @Test("editing an absent message is unknown, and writes nothing")
    func editRejectsAbsentTargets() async throws {
        let seed = Log.withCompletedTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)
        let ghost = MessageID(uuid(0xDEAD))

        await #expect(throws: LedgerError.unknownMessage(ghost)) {
            try await fixture.store.edit(ghost, content: "nowhere", in: seed.conversation)
        }

        #expect(fixture.written.isEmpty)
        #expect(try await fixture.rows(of: seed.conversation) == seed.rows)
    }

    /// §6.4 case 3: a branch switch is a *bare* `activePathChanged` — one event,
    /// nothing else.
    @Test("switchBranch writes one bare activePathChanged and moves the path")
    func switchBranchMovesThePath() async throws {
        let seed = Log.withCompletedTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)

        try await fixture.store.switchBranch(to: Fix.userA, in: seed.conversation)

        #expect(fixture.written.map(\.payload) == [.activePathChanged(endpoint: Fix.userA)])
        #expect(try await fixture.store.conversation(seed.conversation).activePath == [Fix.userA])
    }

    /// No role requirement: moving between sibling *responses* is what a branch
    /// switcher is for.
    @Test("switching onto an assistant endpoint is legal")
    func switchBranchAcceptsAssistantEndpoints() async throws {
        let seed = Log.withCompletedTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)

        try await fixture.store.switchBranch(to: Fix.userA, in: seed.conversation)
        try await fixture.store.switchBranch(to: Fix.assistantA, in: seed.conversation)

        #expect(try await fixture.store.conversation(seed.conversation).activePath == [Fix.userA, Fix.assistantA])
    }

    /// The layer difference, made executable: the *store* throws where the
    /// reducer would quarantine (§6.6 row 12). Same fact — this endpoint never
    /// existed — reported on the channel each layer actually has.
    @Test("switching to a never-existent endpoint is unknown, and writes nothing")
    func switchBranchRejectsAbsentEndpoints() async throws {
        let seed = Log.withCompletedTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)
        let ghost = MessageID(uuid(0xDEAD))

        await #expect(throws: LedgerError.unknownMessage(ghost)) {
            try await fixture.store.switchBranch(to: ghost, in: seed.conversation)
        }

        #expect(fixture.written.isEmpty)
        #expect(try await fixture.rows(of: seed.conversation) == seed.rows)
    }

    /// **§6.5's mid-stream legality**, at the level Phase 2 can reach:
    /// single-flight gates generation *starts*, not ledger writes, so a taken
    /// slot must not block either tree verb. Phase 3 runs the same assertion
    /// against a genuinely parked generation; this one proves the verbs do not
    /// consult the live set at all.
    @Test("edit and switchBranch stay legal while a generation slot is taken")
    func treeVerbsIgnoreTheLiveSet() async throws {
        let seed = threadWithSecondTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)

        try await fixture.store.reserve(seed.conversation)

        let replacement = try await fixture.store.edit(Fix.userB, content: "shorter", in: seed.conversation)
        try await fixture.store.switchBranch(to: Fix.userB, in: seed.conversation)

        #expect(try await fixture.store.conversation(seed.conversation).activePath.last == Fix.userB)
        #expect(replacement == Fix.edited)

        // And the slot really was taken while both ran.
        await #expect(throws: LedgerError.generationInFlight(seed.conversation)) {
            try await fixture.store.reserve(seed.conversation)
        }
    }

    @Test("the tree verbs produce a healthy log the cache agrees with")
    func healthyLog() async throws {
        let seed = threadWithSecondTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x17)

        let replacement = try await fixture.store.edit(Fix.userB, content: "shorter", in: seed.conversation)
        try await fixture.store.switchBranch(to: Fix.userA, in: seed.conversation)
        try await fixture.store.switchBranch(to: replacement, in: seed.conversation)

        let problems = try await healthyLogProblems(
            seed.conversation,
            in: fixture.store,
            backedBy: fixture.backing
        )
        #expect(problems.isEmpty, "\(problems)")
    }

    /// The reservation is a plain in-memory slot, so releasing it must make the
    /// conversation startable again — D24's rollback depends on exactly this.
    @Test("releasing a reservation frees the slot")
    func reservationRoundTrips() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()

        try await fixture.store.reserve(convo.id)
        await #expect(throws: LedgerError.generationInFlight(convo.id)) {
            try await fixture.store.reserve(convo.id)
        }

        await fixture.store.release(convo.id)
        try await fixture.store.reserve(convo.id)
    }
}

// MARK: - Phase 3: generation verbs

@Suite("Store — generation verbs")
struct StoreGenerationTests {

    @Test("send commits its user message and generationStarted together, then streams")
    func sendIsAtomic() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        let driver = ScriptedDriver(saying: "A valley fold")

        let outcome = try await fixture.store.send("Explain valley folds", in: convo.id, using: driver)

        #expect(outcome == .completed(Fix.stopInfo))
        #expect(fixture.appends.map { $0.map(\.payload) } == [
            [.conversationCreated(title: nil)],
            // §6.5's start atomicity: one transaction, and nothing more —
            // auto-extend is a fold rule, not an event.
            [
                .userMessageAppended(message: firstUser, content: "Explain valley folds", parent: nil),
                .generationStarted(generation: Fix.genA, message: firstAssistant, parent: firstUser, model: Fix.model),
            ],
            // §7.4: always flush before the terminal.
            [.deltaAppended(generation: Fix.genA, text: "A valley fold")],
            [.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo))],
        ])
    }

    @Test("the completed turn reduces to a visible thread")
    func sendProducesAThread() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()

        _ = try await fixture.store.send(
            "Explain valley folds",
            in: convo.id,
            using: ScriptedDriver([.delta("A valley "), .delta("fold is…")])
        )

        let read = try await fixture.store.conversation(convo.id)
        #expect(read.activePath == [firstUser, firstAssistant])
        #expect(read.messages[firstAssistant]?.state == .complete(MessageContent(text: "A valley fold is…")))
        #expect(read.messages[firstAssistant]?.stopInfo == Fix.stopInfo)
    }

    /// D21 constraint 3: the *requested* descriptor is the driver's, and the
    /// store copies it rather than inventing one (§7.8 — nothing in the
    /// framework exposes model identity).
    @Test("the driver's ModelDescriptor rides generationStarted")
    func modelDescriptorFlowsFromTheDriver() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        let claude = ModelDescriptor(provider: "anthropic", model: "claude-opus-5")

        _ = try await fixture.store.send("hi", in: convo.id, using: ScriptedDriver(saying: "hello", model: claude))

        #expect(try await fixture.store.conversation(convo.id).messages[firstAssistant]?.model == claude)
    }

    /// D21 constraint 4: the store hands over **reduction output**, not the log.
    @Test("the driver receives the instructions and the active path")
    func driverReceivesRehydrationMaterial() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        try await fixture.store.setInstructions("You are an origami tutor.", in: convo.id)
        let driver = ScriptedDriver(saying: "ok")

        _ = try await fixture.store.send("Explain valley folds", in: convo.id, using: driver)

        let request = try #require(driver.received.first)
        #expect(request.conversation == convo.id)
        #expect(request.instructions == "You are an origami tutor.")
        #expect(request.context.map(\.id) == [firstUser])
        #expect(request.context.first?.state == .complete(MessageContent(text: "Explain valley folds")))
    }

    /// §6.4 case 2, first half: the parent *is* the endpoint, so auto-extend
    /// fires and no path event is needed.
    @Test("respond at the endpoint emits no path event")
    func respondAtTheEndpoint() async throws {
        let seed = Log.withUserMessage()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x1F, generationsFrom: 0x30)

        _ = try await fixture.store.respond(to: Fix.userA, in: seed.conversation, using: ScriptedDriver(saying: "ok"))

        #expect(fixture.appends.first?.map(\.payload) == [
            .generationStarted(generation: Fix.genB, message: Fix.assistantA, parent: Fix.userA, model: Fix.model),
        ])
    }

    /// §6.4 case 2, second half — **the case Phase 2 could not reach.** A
    /// generation the user asked for must never stream invisibly, so an
    /// off-endpoint target carries its path event in the same transaction.
    @Test("respond off the endpoint moves the path in the same transaction")
    func respondOffTheEndpointMovesThePath() async throws {
        let seed = Log.withCompletedTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x20, generationsFrom: 0x30)

        // The endpoint is `assistantA`; the target is the user message above it.
        _ = try await fixture.store.respond(to: Fix.userA, in: seed.conversation, using: ScriptedDriver(saying: "again"))

        #expect(fixture.appends.first?.map(\.payload) == [
            .generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.userA, model: Fix.model),
            .activePathChanged(endpoint: Fix.assistantB),
        ])

        let read = try await fixture.store.conversation(seed.conversation)
        #expect(read.activePath == [Fix.userA, Fix.assistantB])
        // The old response survives as a sibling — DoD-1's shape, falling out of
        // the model rather than being a feature.
        #expect(read.messages.siblings(of: Fix.assistantB).map(\.id) == [Fix.assistantA])
    }

    @Test("regenerate is exactly respond on the target's parent")
    func regenerateIsSugar() async throws {
        let seed = Log.withCompletedTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x20, generationsFrom: 0x30)

        _ = try await fixture.store.regenerate(Fix.assistantA, in: seed.conversation, using: ScriptedDriver(saying: "again"))

        #expect(fixture.appends.first?.map(\.payload) == [
            .generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.userA, model: Fix.model),
            .activePathChanged(endpoint: Fix.assistantB),
        ])
        #expect(try await fixture.store.conversation(seed.conversation).activePath == [Fix.userA, Fix.assistantB])
    }

    @Test("respond rejects an assistant target, regenerate rejects a user one")
    func eligibilityIsSymmetric() async throws {
        let seed = Log.withCompletedTurn()
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x20, generationsFrom: 0x30)

        await #expect(throws: LedgerError.ineligibleTarget(
            message: Fix.assistantA, expected: .user, found: .assistant
        )) {
            try await fixture.store.respond(to: Fix.assistantA, in: seed.conversation, using: ScriptedDriver())
        }
        await #expect(throws: LedgerError.ineligibleTarget(
            message: Fix.userA, expected: .assistant, found: .user
        )) {
            try await fixture.store.regenerate(Fix.userA, in: seed.conversation, using: ScriptedDriver())
        }

        #expect(fixture.written.isEmpty)
        #expect(try await fixture.rows(of: seed.conversation) == seed.rows)
    }

    /// N10, from the *reading* side: a nil-parent `generationStarted` is wire
    /// headroom the reducer accepts and this store never writes — so it declines
    /// to regenerate one rather than authoring the shape N10 reserves.
    @Test("regenerating a root-level assistant message is unsupported")
    func regenerateRejectsRootLevelAssistants() async throws {
        var seed = Log.opened()
        seed.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: nil, model: Fix.model))
        seed.append(.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))
        let fixture = try await StoreUnderTest.continuing(seed, messagesFrom: 0x20, generationsFrom: 0x30)

        await #expect(throws: LedgerError.unsupportedTarget(message: Fix.assistantA)) {
            try await fixture.store.regenerate(Fix.assistantA, in: seed.conversation, using: ScriptedDriver())
        }

        #expect(fixture.written.isEmpty)
    }

    @Test("a generation verb on an unknown conversation throws and writes nothing")
    func unknownConversationThrows() async throws {
        let fixture = try StoreUnderTest()

        await #expect(throws: LedgerError.unknownConversation(Fix.foreign)) {
            try await fixture.store.send("hi", in: Fix.foreign, using: ScriptedDriver())
        }
        #expect(fixture.written.isEmpty)
    }
}

/// §6.5's concurrency rules: one generation per conversation, unrestricted
/// across them. Every interleaving below is driven by `Latch` at a point the
/// test chose (D26) — no sleeps, no seeds, and a failure reproduces by
/// re-running.
@Suite("Store — single-flight and start atomicity", .timeLimit(.minutes(1)))
struct StoreSingleFlightTests {

    @Test("a second starter throws generationInFlight and records nothing")
    func secondStarterIsTurnedAway() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        let latch = Latch()

        let running = Task {
            try await fixture.store.send(
                "first",
                in: convo.id,
                using: ScriptedDriver([.delta("half "), .pause(latch), .delta("done")])
            )
        }
        await latch.waitForArrival()

        let before = fixture.written.count
        await #expect(throws: LedgerError.generationInFlight(convo.id)) {
            try await fixture.store.send("second", in: convo.id, using: ScriptedDriver())
        }
        // §6.5: a losing racer records **nothing** — no orphaned user message,
        // no yanked path.
        #expect(fixture.written.count == before)

        await latch.release()
        #expect(try await running.value == .completed(Fix.stopInfo))
    }

    @Test("two conversations generate at once")
    func crossConversationConcurrencyIsFree() async throws {
        let fixture = try StoreUnderTest()
        let first = try await fixture.store.createConversation(title: "first")
        let second = try await fixture.store.createConversation(title: "second")
        let firstLatch = Latch()
        let secondLatch = Latch()

        let a = Task {
            try await fixture.store.send("a", in: first.id, using: ScriptedDriver([.pause(firstLatch), .delta("A")]))
        }
        await firstLatch.waitForArrival()

        // The second starts while the first is provably mid-flight — which is
        // the claim: single-flight is per conversation, not per store.
        let b = Task {
            try await fixture.store.send("b", in: second.id, using: ScriptedDriver([.pause(secondLatch), .delta("B")]))
        }
        await secondLatch.waitForArrival()

        await firstLatch.release()
        await secondLatch.release()

        #expect(try await a.value == .completed(Fix.stopInfo))
        #expect(try await b.value == .completed(Fix.stopInfo))
        #expect(try await fixture.store.conversation(first.id).activeMessages.last?.state
                == .complete(MessageContent(text: "A")))
        #expect(try await fixture.store.conversation(second.id).activeMessages.last?.state
                == .complete(MessageContent(text: "B")))
    }

    /// **D24's rollback.** A start append that fails must leave the slot free —
    /// otherwise one disk hiccup wedges the conversation as permanently
    /// "generating", with no generation to cancel and no way back.
    @Test("a failed start releases the reservation and leaves the log untouched")
    func failedStartRollsBack() async throws {
        let backing = try SQLitePersistenceStore(.inMemory)
        let seed = Log.withUserMessage()
        _ = try await backing.append(seed.records, to: seed.conversation)

        let fixture = try StoreUnderTest(over: FlakyStore(backing, tolerating: 0))

        do {
            _ = try await fixture.store.send("hi", in: seed.conversation, using: ScriptedDriver())
            Issue.record("expected the start append to fail")
        } catch let error as LedgerError {
            guard case .persistenceFailure = error else {
                Issue.record("expected .persistenceFailure, got \(error)")
                return
            }
        }

        // The log is untouched — the seam's batch is all-or-nothing…
        #expect(try await backing.events(in: seed.conversation, from: 1) == seed.rows)
        // …and the slot is free, so the conversation is not wedged.
        try await fixture.store.reserve(seed.conversation)
    }
}

/// §7.4's cadence: only deltas coalesce, everything else appends synchronously,
/// and the buffer is always flushed before the terminal.
@Suite("Store — the flush loop")
struct StoreFlushTests {

    /// Deterministic without controlling a clock: a one-character bound makes
    /// every delta due, and `.zero` would too.
    private static let everyDelta: DeltaFlushPolicy = .flushing(every: .zero, orAfterCharacters: 1)
    /// Nothing is ever due, so only the mandatory pre-terminal flush fires.
    private static let never: DeltaFlushPolicy = .flushing(every: .seconds(3600), orAfterCharacters: .max)

    @Test("a flush-per-delta policy writes one row per delta")
    func flushesPerDelta() async throws {
        let fixture = try StoreUnderTest(deltaFlush: Self.everyDelta)
        let convo = try await fixture.store.createConversation()

        _ = try await fixture.store.send(
            "q",
            in: convo.id,
            using: ScriptedDriver([.delta("one "), .delta("two "), .delta("three")])
        )

        #expect(fixture.written.compactMap { payload -> String? in
            guard case .deltaAppended(_, let text) = payload.payload else { return nil }
            return text
        } == ["one ", "two ", "three"])
    }

    /// The buffer's whole purpose: a 60 s generation should not be ~240 separate
    /// transactions when nothing needs them to be.
    @Test("a policy that never comes due still flushes once, before the terminal")
    func coalescesButNeverLoses() async throws {
        let fixture = try StoreUnderTest(deltaFlush: Self.never)
        let convo = try await fixture.store.createConversation()

        _ = try await fixture.store.send(
            "q",
            in: convo.id,
            using: ScriptedDriver([.delta("one "), .delta("two "), .delta("three")])
        )

        let payloads = fixture.written.map(\.payload)
        #expect(payloads.filter { if case .deltaAppended = $0 { true } else { false } }
                == [.deltaAppended(generation: Fix.genA, text: "one two three")])
        // …and it landed *before* the terminal, which is not a policy choice.
        #expect(payloads.last == .generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))
        #expect(try await fixture.store.conversation(convo.id).messages[firstAssistant]?.state
                == .complete(MessageContent(text: "one two three")))
    }

    /// Only `deltaAppended` coalesces (§7.4). A tool record forces the buffer
    /// out first, or the log would claim the tool ran before text that preceded
    /// it — and I4 would reject nothing, so the corruption would be silent.
    @Test("a tool record flushes buffered text ahead of itself")
    func toolRecordsOrderAfterTheirText() async throws {
        let fixture = try StoreUnderTest(deltaFlush: Self.never)
        let convo = try await fixture.store.createConversation()
        let record = ToolRecord(name: "lookupFold", status: .succeeded)

        _ = try await fixture.store.send(
            "q",
            in: convo.id,
            using: ScriptedDriver([.delta("before "), .toolRecord(record), .delta("after")])
        )

        #expect(fixture.written.map(\.payload).suffix(4) == [
            .deltaAppended(generation: Fix.genA, text: "before "),
            .toolInvocationRecorded(generation: Fix.genA, record: record),
            .deltaAppended(generation: Fix.genA, text: "after"),
            .generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)),
        ])
        #expect(try await fixture.store.conversation(convo.id).messages[firstAssistant]?.toolRecords == [record])
    }

    /// The healthy-log property over a *streaming* log, with a flush landing
    /// mid-generation — the Phase 3 gate's version of it.
    @Test("a streaming generation produces a healthy log the cache agrees with")
    func healthyStreamingLog() async throws {
        let fixture = try StoreUnderTest(deltaFlush: Self.everyDelta)
        let convo = try await fixture.store.createConversation(title: "streaming")

        _ = try await fixture.store.send(
            "q",
            in: convo.id,
            using: ScriptedDriver([
                .delta("one "),
                .toolRecord(ToolRecord(name: "t", status: .succeeded)),
                .delta("two "),
                .delta("three"),
            ])
        )
        _ = try await fixture.store.respond(to: firstUser, in: convo.id, using: ScriptedDriver(saying: "again"))

        let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
        #expect(problems.isEmpty, "\(problems)")
    }

    /// A failure is a *terminal*, not a throw (§7.2) — including the zero-token
    /// case, which renders as an empty failed bubble showing how to recover.
    @Test("a driver failure lands as an outcome, not an exception")
    func failuresAreOutcomes() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        let failure = Outcome.failed(.providerFailure(status: 401, code: nil, message: nil))

        let outcome = try await fixture.store.send(
            "q",
            in: convo.id,
            using: ScriptedDriver([], ending: failure)
        )

        #expect(outcome == failure)
        let read = try await fixture.store.conversation(convo.id)
        #expect(read.messages[firstAssistant]?.state == .failed(
            partial: "",
            error: .providerFailure(status: 401, code: nil, message: nil),
            recoverability: .recoverableUpstream(.reauthenticate)
        ))
    }
}

/// Reentrancy is the whole reason this cache is subtle: an actor yields at every
/// `await`, so both hazards below involve a verb resuming into a world that
/// changed underneath it. Both are driven by `Latch` at a point the test chose
/// rather than by timing (D26's discipline, one phase early).
@Suite("Store — cache reentrancy", .timeLimit(.minutes(1)))
struct StoreCacheReentrancyTests {

    /// A cold load that resumes *after* someone else already advanced the cache
    /// must not publish its older fold. Publishing it would rewind the cache
    /// behind a completed write, and the next append would then fold its tail
    /// onto a state missing an event — a gap in memory that disk never had.
    @Test("a late cold load does not rewind the cache behind a completed write")
    func lateColdLoadDoesNotRewind() async throws {
        let backing = try SQLitePersistenceStore(.inMemory)
        let seed = Log.opened(title: "before")
        _ = try await backing.append(seed.records, to: seed.conversation)
        let id = seed.conversation

        let latch = Latch()
        let fixture = try StoreUnderTest(
            over: ParkingStore(backing, parkingFirst: .events, at: latch)
        )

        // A read cold-loads and parks, holding the pre-title fold.
        let reader = Task { try await fixture.store.conversation(id) }
        await latch.waitForArrival()

        // Meanwhile a write cold-loads (a second `events` call, unparked),
        // appends, and advances the cache to the title.
        try await fixture.store.setTitle("after", in: id)

        await latch.release()
        _ = try await reader.value

        #expect(try await fixture.store.conversation(id).title == "after")
        let problems = try await healthyLogProblems(id, in: fixture.store, backedBy: backing)
        #expect(problems.isEmpty, "\(problems)")
    }

    /// Two writes to one conversation both await the database, and nothing
    /// orders their resumptions — so the later-sequenced tail can arrive first.
    /// Folding it would raise a `sequenceGap` against a log that has no gap.
    /// Dropping the cache costs one replay and cannot be wrong.
    @Test("a tail that does not continue the cache drops it rather than folding a hole")
    func outOfOrderTailDropsTheCache() async throws {
        let backing = try SQLitePersistenceStore(.inMemory)
        let seed = Log.opened(title: "before")
        _ = try await backing.append(seed.records, to: seed.conversation)
        let id = seed.conversation

        let latch = Latch()
        let fixture = try StoreUnderTest(
            over: ParkingStore(backing, parkingFirst: .append, at: latch)
        )

        // Warm the cache so neither write below takes the cold-load path.
        _ = try await fixture.store.conversation(id)

        // The first write commits, then parks before folding forward.
        let first = Task { try await fixture.store.setTitle("first", in: id) }
        await latch.waitForArrival()

        // The second commits and folds forward onto a cache the first write has
        // already moved past on disk.
        try await fixture.store.setInstructions("be brief", in: id)

        await latch.release()
        try await first.value

        let problems = try await healthyLogProblems(id, in: fixture.store, backedBy: backing)
        #expect(problems.isEmpty, "\(problems)")
    }
}

// MARK: - Phase 4: cancellation, deletion, snapshot refresh

/// §7.5's two entry points, one semantics — and §7.2's straddle, which is the
/// line between them.
///
/// Every point below is *parked*, not slept on (D26): the test cancels at a
/// moment it chose, so there is no seed to manage, no flake, and a failure
/// reproduces by re-running.
/// `.timeLimit` here is a backstop with a **known limit, measured rather than
/// assumed**. Two of the guards these suites protect — delete's cancel-first
/// sequencing, and honouring a stop that lands in the reservation window — fail
/// as *deadlocks* rather than as wrong answers, because what they guarantee is
/// that something eventually finishes. Mutating either hangs the suite, and the
/// time limit does **not** rescue it: the trait cancels the *test's* task, while
/// these tests are suspended on `await someTask.value` for an **unstructured**
/// task that never completes — an await cancellation cannot interrupt.
///
/// It is kept because it does cover the hang shapes that *are* cancellable, and
/// because a stated limitation beats an unstated one. Diagnose a genuine hang
/// from the last `Test "…" started` line.
@Suite("Store — cancellation", .timeLimit(.minutes(1)))
struct StoreCancellationTests {

    /// The number of `generationEnded` events in a conversation — I3's
    /// "exactly one terminal per generation", counted rather than argued.
    private func terminals(in rows: [LoadedEvent]) -> [Outcome] {
        rows.compactMap { row in
            guard case .decoded(let event) = row,
                  case .generationEnded(_, let outcome) = event.payload
            else { return nil }
            return outcome
        }
    }

    @Test("cancelGeneration winds the driver down and records .cancelled")
    func cancelRecordsATerminal() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        let latch = Latch()

        let running = Task {
            try await fixture.store.send(
                "q",
                in: convo.id,
                using: ScriptedDriver([.delta("half an ans"), .pause(latch), .delta("wer")])
            )
        }
        await latch.waitForArrival()
        await fixture.store.cancelGeneration(in: convo.id)

        // §11's documented deviation: the recording operation *succeeded*, so
        // cancellation is a returned terminal, not a thrown error.
        #expect(try await running.value == .cancelled)

        let rows = try await fixture.rows(of: convo.id)
        #expect(terminals(in: rows) == [.cancelled])

        // §7.5: partial content retained. Cancelled ≠ failed ≠ interrupted —
        // three distinct UI treatments, and this is the first.
        let read = try await fixture.store.conversation(convo.id)
        #expect(read.activeMessages.last?.state == .cancelled(partial: "half an ans"))
    }

    @Test("cancelGeneration with nothing live is a no-op, not a throw")
    func cancelWithNothingLive() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()

        await fixture.store.cancelGeneration(in: convo.id)
        await fixture.store.cancelGeneration(in: Fix.foreign)

        #expect(fixture.written.count == 1, "only the genesis")
    }

    /// §7.2's far side: cancelled *after* the append, so the call returns
    /// `.cancelled` — the same place `cancelGeneration` lands, by design.
    @Test("Task-cancel after the start append returns .cancelled")
    func taskCancelPostAppendReturns() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        let latch = Latch()

        let running = Task {
            try await fixture.store.send(
                "q",
                in: convo.id,
                using: ScriptedDriver([.delta("partial"), .pause(latch)])
            )
        }
        await latch.waitForArrival()
        running.cancel()

        #expect(try await running.value == .cancelled)
        #expect(terminals(in: try await fixture.rows(of: convo.id)) == [.cancelled])
    }

    /// §7.2's near side: cancelled *before* the append, so Swift's convention
    /// holds — nothing started, nothing to record, `CancellationError`. Parked
    /// on the cold load, which is the one suspension point before the reserve.
    @Test("Task-cancel before the start append throws CancellationError")
    func taskCancelPreAppendThrows() async throws {
        let backing = try SQLitePersistenceStore(.inMemory)
        let seed = Log.opened(title: "seeded")
        _ = try await backing.append(seed.records, to: seed.conversation)

        let latch = Latch()
        let fixture = try StoreUnderTest(
            over: ParkingStore(backing, parkingFirst: .events, at: latch),
            identifiers: ScriptedIdentifiers(eventsFrom: 0x101, messagesFrom: 0x1F, generationsFrom: 0x2F),
            clockFrom: Log.base.addingTimeInterval(1)
        )

        let running = Task {
            try await fixture.store.send("q", in: seed.conversation, using: ScriptedDriver(saying: "never"))
        }
        await latch.waitForArrival()
        running.cancel()
        await latch.release()

        await #expect(throws: CancellationError.self) { try await running.value }

        // Nothing started, so nothing recorded — and the slot is not wedged.
        #expect(fixture.written.isEmpty)
        #expect(try await backing.events(in: seed.conversation, from: 1) == seed.rows)
        try await fixture.store.reserve(seed.conversation)
    }

    /// The window D24 opens: a stop pressed while the start append is still in
    /// flight has no task to cancel yet. Dropping it would run the generation to
    /// completion after the user said stop.
    @Test("a stop during the reservation window is honoured once the generation starts")
    func cancelDuringTheReservationWindow() async throws {
        let backing = try SQLitePersistenceStore(.inMemory)
        let seed = Log.opened(title: "seeded")
        _ = try await backing.append(seed.records, to: seed.conversation)

        let latch = Latch()
        let fixture = try StoreUnderTest(
            over: ParkingStore(backing, parkingFirst: .append, at: latch),
            identifiers: ScriptedIdentifiers(eventsFrom: 0x101, messagesFrom: 0x1F, generationsFrom: 0x2F),
            clockFrom: Log.base.addingTimeInterval(1)
        )

        let neverReleased = Latch()
        let running = Task {
            try await fixture.store.send(
                "q",
                in: seed.conversation,
                using: ScriptedDriver([.pause(neverReleased), .delta("unreachable")])
            )
        }
        // The start batch has committed and is parked *inside* the append, so
        // the slot is still `.reserved` — there is no task to cancel.
        await latch.waitForArrival()
        await fixture.store.cancelGeneration(in: seed.conversation)
        await latch.release()

        #expect(try await running.value == .cancelled)
        #expect(terminals(in: try await fixture.rows(of: seed.conversation)) == [.cancelled])
    }

    /// The one genuinely racy case, and §7.5 already calls it benign: first
    /// append wins, I3 quarantines any loser. Asserted by **outcome invariant**
    /// over many runs rather than by controlling the timing (D26).
    @Test("cancel racing a natural terminal still yields exactly one terminal")
    func cancelRacingCompletion() async throws {
        for _ in 0..<40 {
            let fixture = try StoreUnderTest()
            let convo = try await fixture.store.createConversation()

            let running = Task {
                try await fixture.store.send("q", in: convo.id, using: ScriptedDriver(saying: "quick"))
            }
            await fixture.store.cancelGeneration(in: convo.id)
            let outcome = try await running.value

            let rows = try await fixture.rows(of: convo.id)
            let ends = terminals(in: rows)
            #expect(ends.count == 1, "exactly one terminal (I3)")
            #expect(ends.first == outcome, "the returned outcome is the recorded one")

            let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
            #expect(problems.isEmpty, "\(problems)")
        }
    }
}

/// **The rehydration gap** (M6-PLAN A2, from the M5 boundary audit 2026-07-28).
///
/// The read that assembles a `GenerationRequest` (§7.1) is the last thing that
/// can fail *after* the start append, and it used to sit in a place covered by no
/// guard at all: past `generate`'s rollback, ahead of `drive`'s `defer`. Two
/// failures live there and both were mishandled — a throw wedged single-flight
/// forever, and a task-cancel escaped as a post-append `CancellationError`, which
/// §7.2 says cannot happen.
///
/// Both tests need the read to go to **disk**, since a warm cache reads nothing.
/// The eviction is *injected* rather than raced: D29 drops the cache whenever a
/// tail does not continue it, which a mid-flight `edit` can cause for real, but
/// reproducing that by racing two verbs would test the scheduler instead of the
/// gap.
@Suite("Store — the rehydration gap", .timeLimit(.minutes(1)))
struct StoreRehydrationGapTests {

    /// Seeds a genesis **below** every wrapper — arming the park or the read gate
    /// must not consume either during setup — and returns a store whose **start
    /// append parks**, so a test can hold the window between the commit and the
    /// rehydration read open and act inside it.
    private func parkedStart() async throws -> (
        fixture: StoreUnderTest,
        conversation: ConversationID,
        reads: ReadHostileStore,
        latch: Latch
    ) {
        let sqlite = try SQLitePersistenceStore(.inMemory)
        let seed = Log.opened(title: "seeded")
        _ = try await sqlite.append(seed.records, to: seed.conversation)

        let reads = ReadHostileStore(sqlite)
        let latch = Latch()
        let fixture = try StoreUnderTest(
            over: ParkingStore(reads, parkingFirst: .append, at: latch),
            identifiers: ScriptedIdentifiers(eventsFrom: 0x101, messagesFrom: 0x1F, generationsFrom: 0x2F),
            clockFrom: Log.base.addingTimeInterval(1)
        )
        return (fixture, seed.conversation, reads, latch)
    }

    @Test("a failed rehydration read throws, frees the slot, and leaves the generation open")
    func readFailureDoesNotWedgeSingleFlight() async throws {
        let (fixture, conversation, reads, latch) = try await parkedStart()

        let running = Task {
            try await fixture.store.send("q", in: conversation, using: ScriptedDriver(saying: "never reached"))
        }
        // Parked *inside* the start append: the batch has committed, so the
        // generation exists in the log and §7.2 is now in force.
        await latch.waitForArrival()
        await fixture.store.evict(conversation)
        reads.isFailingReads = true
        await latch.release()

        do {
            _ = try await running.value
            Issue.record("expected the rehydration read to fail")
        } catch let error as LedgerError {
            // Rev 8's "couldn't record" clause, not "never started".
            guard case .persistenceFailure = error else {
                Issue.record("expected .persistenceFailure, got \(error)")
                return
            }
        }

        // **The wedge.** A throw in that window left the slot claimed forever, so
        // the conversation could never generate again — a failure the verb's own
        // caller has no way to see and no way to clear.
        try await fixture.store.reserve(conversation)
        await fixture.store.release(conversation)

        // No terminal was written, deliberately: the generation stays open and
        // reduces to `.interrupted`, which says something went wrong where a
        // `.completed` missing its content would claim success.
        reads.isFailingReads = false
        let read = try await fixture.store.conversation(conversation)
        #expect(read.activeMessages.last?.state == .interrupted(partial: ""))
    }

    @Test("a cancellation during the rehydration read returns .cancelled and records its terminal")
    func cancellationDuringTheReadIsRecorded() async throws {
        let (fixture, conversation, _, latch) = try await parkedStart()

        let running = Task {
            try await fixture.store.send("q", in: conversation, using: ScriptedDriver(saying: "never reached"))
        }
        await latch.waitForArrival()
        await fixture.store.evict(conversation)
        // Cancelled with the start append already committed — §7.2's far side, so
        // the answer is a recorded terminal rather than a thrown error, even
        // though the cancellation lands on a *store* read rather than on the
        // driver.
        running.cancel()
        await latch.release()

        #expect(try await running.value == .cancelled)

        let rows = try await fixture.rows(of: conversation)
        let terminals = rows.compactMap { row -> Outcome? in
            guard case .decoded(let event) = row,
                  case .generationEnded(_, let outcome) = event.payload
            else { return nil }
            return outcome
        }
        #expect(terminals == [.cancelled], "the cancellation must be recorded, not merely returned")
        try await fixture.store.reserve(conversation)
    }
}

/// §9's deletion semantics: cancel first, then an irreversible transactional
/// DELETE — and the cache goes with it.
@Suite("Store — deletion", .timeLimit(.minutes(1)))
struct StoreDeletionTests {

    @Test("delete removes the conversation and evicts its cache")
    func deleteRemovesEverything() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation(title: "doomed")
        _ = try await fixture.store.send("q", in: convo.id, using: ScriptedDriver(saying: "a"))

        try await fixture.store.deleteConversation(convo.id)

        #expect(try await fixture.rows(of: convo.id).isEmpty)
        #expect(try await fixture.backing.conversationSummaries().isEmpty)
        await #expect(throws: LedgerError.unknownConversation(convo.id)) {
            try await fixture.store.conversation(convo.id)
        }
    }

    /// **Cancel-first (§9).** The in-flight verb returns `.cancelled`, never a
    /// persistence error, and no row outlives the DELETE — which is only true
    /// because the delete *waits* for the terminal rather than trusting actor
    /// isolation to order it.
    @Test("delete cancels an in-flight generation first, and nothing survives it")
    func deleteCancelsFirst() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        let latch = Latch()

        let running = Task {
            try await fixture.store.send(
                "q",
                in: convo.id,
                using: ScriptedDriver([.delta("half"), .pause(latch), .delta("rest")])
            )
        }
        await latch.waitForArrival()

        try await fixture.store.deleteConversation(convo.id)

        #expect(try await running.value == .cancelled)
        #expect(try await fixture.rows(of: convo.id).isEmpty, "a terminal appended after the DELETE would resurrect the log")
        #expect(try await fixture.backing.conversationSummaries().isEmpty)
    }

    /// **The reservation window** (M6-PLAN A1, from the M5 boundary audit
    /// 2026-07-28). Waiting only on `.running` left D24's window uncovered: a
    /// `.reserved` slot means the start append is *in flight*, holding a
    /// transaction this verb cannot see. Racing it produces one of the two
    /// artifacts ``ConversationStore/deleteConversation(_:)``'s own doc says
    /// cannot happen — rows written into an erased conversation, or a terminal
    /// appended after the DELETE — depending only on which commit wins.
    @Test("delete waits out a claimed-but-unconfirmed start")
    func deleteWaitsOutTheReservationWindow() async throws {
        let sqlite = try SQLitePersistenceStore(.inMemory)
        let seed = Log.opened(title: "doomed")
        _ = try await sqlite.append(seed.records, to: seed.conversation)

        let latch = Latch()
        let fixture = try StoreUnderTest(
            over: ParkingStore(sqlite, parkingFirst: .append, at: latch),
            identifiers: ScriptedIdentifiers(eventsFrom: 0x101, messagesFrom: 0x1F, generationsFrom: 0x2F),
            clockFrom: Log.base.addingTimeInterval(1)
        )

        let neverReleased = Latch()
        let starting = Task {
            try await fixture.store.send(
                "q",
                in: seed.conversation,
                using: ScriptedDriver([.pause(neverReleased), .delta("unreachable")])
            )
        }
        // The start batch has committed and is parked inside the append, so the
        // slot is `.reserved`: nothing to cancel, no terminal, and a DELETE
        // issued now would race a transaction it cannot observe.
        await latch.waitForArrival()

        let deleting = Task { try await fixture.store.deleteConversation(seed.conversation) }
        // A rendezvous, not a hoped-for interleaving (§10.4's discipline applied
        // to a wait): releasing the append before the delete is *inside* its wait
        // would silently fall back to exercising the already-correct `.running`
        // path, and the test would pass without touching the bug.
        try await spin(until: { await fixture.store.conversationsAwaitingStart.contains(seed.conversation) })
        await latch.release()
        try await deleting.value

        // §9's contract, unchanged: the overridden generation's own verb reports
        // `.cancelled`, never a persistence error.
        #expect(try await starting.value == .cancelled)

        // The terminal was recorded *and then erased*, in that order — which is
        // the whole claim. A terminal appended after the DELETE would still be
        // there, and it would be a genesis-less row.
        let wroteTerminal = fixture.written.contains { record in
            if case .generationEnded = record.payload { true } else { false }
        }
        #expect(wroteTerminal, "the cancellation must be recorded before the DELETE")
        #expect(try await fixture.rows(of: seed.conversation).isEmpty, "no row may outlive the DELETE")
        #expect(try await fixture.backing.conversationSummaries().isEmpty)

        // And the slot is not left claimed on a conversation that no longer exists.
        #expect(await fixture.store.conversationsAwaitingStart.isEmpty)
        try await fixture.store.reserve(seed.conversation)
    }

    /// **A3, the finding two boundary audits and a model checker converged on**
    /// (M6 audit 2026-08-13; TLA+ 2026-08-15; M7-PLAN D44).
    ///
    /// `deleteConversation`'s cancel-and-wait is not atomic with its `DELETE`, so
    /// a *new* starter can interleave at either await and append into a
    /// conversation whose rows are gone. `MAX(sequence)+1` then restarts at 1 and
    /// the log begins with something that is not a genesis — rows that quarantine
    /// under §6.6 row 5 for the rest of the log's life, which is exactly what
    /// §6.5's healthy-log property says the store cannot write.
    ///
    /// The remedy is at the **write boundary**, not in this actor's memory, and
    /// the distinction is what TLC established: an in-memory tombstone covers
    /// *[delete entry, delete completion]* while the interval needing cover is
    /// *[starter's existence read, starter's append]*. The third test below is the
    /// interleaving that separates them.
    ///
    /// Two facts carried the damage past every in-memory check, both verified in
    /// source: `events` has no foreign key to `conversations`, and `append`
    /// validated only that each record named its own target.
    @Test("a starter racing a committed DELETE cannot leave a genesis-less row")
    func starterRacingTheDeleteIsRefused() async throws {
        let latch = Latch()
        let fixture = try StoreUnderTest(
            over: ParkingStore(try SQLitePersistenceStore(.inMemory), parkingFirst: .delete, at: latch)
        )
        let convo = try await fixture.store.createConversation(title: "doomed")

        let deleting = Task { try await fixture.store.deleteConversation(convo.id) }
        // Parked *after* the DELETE committed: the rows are gone, and
        // `deleteConversation` has not returned, so its cache eviction has not
        // run either. A starter arriving now reads a cached fold that says the
        // conversation exists — which is the stale-read hazard an `await` inside
        // an actor creates, and the reason this is a rendezvous rather than a
        // sleep (§10.4).
        await latch.waitForArrival()

        let starting = Task {
            try await fixture.store.send("q", in: convo.id, using: ScriptedDriver(saying: "unreachable"))
        }
        await #expect(throws: LedgerError.unknownConversation(convo.id)) { try await starting.value }

        await latch.release()
        try await deleting.value

        // **The throw above is not the guarantee — this is** (measured, by
        // removing the guard). Without D44 the `send` *still* throws
        // `unknownConversation`, by a longer route: the append lands at sequence
        // 1, `foldForward` sees a tail that does not continue the cache and drops
        // it (D29), the rehydration read reloads cold, and the reloaded log has no
        // genesis. Same error, junk rows on disk. So a test asserting only the
        // throw would have passed against the bug, which is precisely how this
        // one nearly got written.
        #expect(try await fixture.rows(of: convo.id).isEmpty)
        #expect(try await fixture.backing.conversationSummaries().isEmpty)
        // And the store is still usable — a refused batch must not wedge the
        // single-flight slot it reserved.
        try await fixture.store.reserve(convo.id)
        await fixture.store.release(convo.id)
        _ = try await fixture.store.createConversation(title: "after")
    }

    /// The same race entered through delete's **other** await: the one where it is
    /// waiting out the previous generation's wind-down (§9's cancel-first).
    ///
    /// Distinct from the test above because the DELETE has *not* committed here —
    /// the conversation still has rows — so the write boundary does not fire and
    /// the append legitimately succeeds. What must then hold is the older
    /// guarantee: the DELETE, when it commits, erases those rows too, leaving
    /// nothing behind. Included because "the guard covers it" would be the wrong
    /// lesson to take from the first test; single-flight is what covers this one.
    @Test("a starter arriving during delete's cancel-and-wait leaves nothing behind")
    func starterDuringTheWindDownLeavesNothing() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation(title: "doomed")
        let paused = Latch()

        let first = Task {
            try await fixture.store.send(
                "q",
                in: convo.id,
                using: ScriptedDriver([.delta("half"), .pause(paused), .delta("rest")])
            )
        }
        await paused.waitForArrival()

        // Delete cancels the running generation and waits on its task; the wait
        // is an await, so a second starter can enter here.
        let deleting = Task { try await fixture.store.deleteConversation(convo.id) }
        let second = Task {
            try await fixture.store.send("again", in: convo.id, using: ScriptedDriver(saying: "unreachable"))
        }

        // Single-flight is the mechanism here: the first generation still holds
        // the slot, so the second starter is turned away before it can append.
        await #expect(throws: LedgerError.generationInFlight(convo.id)) { try await second.value }

        try await deleting.value
        #expect(try await first.value == .cancelled)
        #expect(try await fixture.rows(of: convo.id).isEmpty)
        #expect(try await fixture.backing.conversationSummaries().isEmpty)
    }

    /// **The interleaving that falsified the tombstone** (M7-PLAN D44, and the
    /// test the M6 audit did not ask for because it did not know it was needed).
    ///
    /// The starter's existence read resolves *before* the delete begins, and its
    /// `reserve` lands *after* the delete has run to completion. Under the
    /// proposed `deleting: Set<ConversationID>` tombstone — set at
    /// `deleteConversation`'s entry, cleared on completion — this starter meets
    /// **no guard at all**: its stale read says the conversation exists, the
    /// tombstone says no deletion is in progress, and both are true statements
    /// about moments that never overlapped. TLC produces the trace with
    /// `deleting = FALSE`, `convExists = FALSE`, deleter terminated.
    ///
    /// Reaching it needs the starter's `existingFold` to *suspend*, which means a
    /// cold fold cache — hence the explicit `evict`. Racing a real eviction would
    /// be testing the scheduler (D29's lesson).
    @Test("a starter whose existence read predates the delete is still refused")
    func staleExistenceReadIsRefused() async throws {
        let latch = Latch()
        let sqlite = try SQLitePersistenceStore(.inMemory)
        let fixture = try StoreUnderTest(over: ParkingStore(sqlite, parkingFirst: .events, at: latch))
        let convo = try await fixture.store.createConversation(title: "doomed")

        // Cold, so `existingFold` must go to disk and therefore must suspend.
        await fixture.store.evict(convo.id)

        let starting = Task {
            try await fixture.store.send("q", in: convo.id, using: ScriptedDriver(saying: "unreachable"))
        }
        // Parked inside the first `events` read, holding rows that say the
        // conversation exists — the stale value, captured before the delete.
        await latch.waitForArrival()

        // The delete runs to *completion* while the starter is parked: its own
        // read is the second `events` call and is not parked, nothing is
        // reserved so the start-wait returns immediately, and the DELETE commits.
        try await fixture.store.deleteConversation(convo.id)

        // Only now does the starter resume — with a fold that says "exists" and a
        // conversation that does not.
        await latch.release()
        await #expect(throws: LedgerError.unknownConversation(convo.id)) { try await starting.value }

        // **The interleaving was genuinely reached**, which is what distinguishes
        // this test from the two above: the starter got past its existence check
        // and *attempted* the append, so only the write transaction could still
        // refuse it. Without this the test would pass just as happily if the
        // starter had been turned away at its read, having never exercised D44.
        let attemptedStart = fixture.attemptedAppends.contains { batch in
            batch.contains { record in
                if case .generationStarted = record.payload { true } else { false }
            }
        }
        #expect(attemptedStart, "the starter must reach the write boundary, or this tests the wrong guard")
        #expect(fixture.written.allSatisfy { record in
            if case .generationStarted = record.payload { false } else { true }
        }, "and the write boundary must refuse it")

        #expect(try await fixture.rows(of: convo.id).isEmpty)
        #expect(try await fixture.backing.conversationSummaries().isEmpty)
    }

    @Test("deleting an unknown conversation throws")
    func deleteUnknown() async throws {
        let fixture = try StoreUnderTest()
        await #expect(throws: LedgerError.unknownConversation(Fix.foreign)) {
            try await fixture.store.deleteConversation(Fix.foreign)
        }
    }
}

/// §9's refresh policy — M4 handoff 2, the trigger nothing owned until now.
@Suite("Store — snapshot refresh")
struct StoreSnapshotRefreshTests {

    @Test("a terminal checkpoints the conversation")
    func terminalRefreshesTheSnapshot() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()

        #expect(try await fixture.backing.latestSnapshot(for: convo.id) == nil)
        _ = try await fixture.store.send("q", in: convo.id, using: ScriptedDriver(saying: "a"))

        let snapshot = try #require(try await fixture.backing.latestSnapshot(for: convo.id))
        #expect(snapshot.upToSequence == 5, "genesis + user + start + delta + terminal")
        #expect(snapshot.foldedState != nil, "the checkpoint is usable, not merely present")
    }

    /// The M4 cold-open criterion, now driven by the actor's **own** trigger
    /// rather than a hand-placed snapshot: reopening replays at most the suffix
    /// after the newest terminal.
    @Test("a cold reopen after refresh replays at most one generation's suffix")
    func coldReopenReplaysASuffix() async throws {
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .zero, orAfterCharacters: 1))
        let convo = try await fixture.store.createConversation()
        for turn in 0..<5 {
            _ = try await fixture.store.send(
                "q\(turn)",
                in: convo.id,
                using: ScriptedDriver([.delta("a"), .delta("b"), .delta("c")])
            )
        }

        let before = fixture.rowsRead
        _ = try await fixture.reopened().conversation(convo.id)
        let replayed = fixture.rowsRead - before

        #expect(replayed == 0, "the newest checkpoint sits on the last terminal, so nothing is left to replay")
    }

    /// The floor exists for logs that reach no terminal at all — a conversation
    /// of nothing but metadata edits would otherwise never checkpoint.
    @Test("the event floor checkpoints a conversation that never terminates")
    func eventFloorFires() async throws {
        let backing = try SQLitePersistenceStore(.inMemory)
        let store = ConversationStore(
            persistence: backing,
            snapshots: .refreshing(afterEachGeneration: true, orAfterEvents: 4),
            identifiers: ScriptedIdentifiers(),
            now: SteppingClock().now
        )
        let convo = try await store.createConversation()

        // Genesis is sequence 1, so drift is measured from there: two titles
        // leave the log at 3, one short of the floor.
        for index in 0..<2 {
            try await store.setTitle("t\(index)", in: convo.id)
        }
        #expect(try await backing.latestSnapshot(for: convo.id) == nil, "three events is under the floor of four")

        try await store.setTitle("t2", in: convo.id)
        let snapshot = try #require(try await backing.latestSnapshot(for: convo.id))
        #expect(snapshot.upToSequence == 4)
    }

    /// Best-effort means best-effort: a checkpoint that cannot be written costs
    /// replay time, never the generation.
    @Test("a snapshot save failure is shrugged off")
    func snapshotFailuresAreShrugged() async throws {
        let fixture = try StoreUnderTest(over: SnapshotHostileStore(try SQLitePersistenceStore(.inMemory)))
        let convo = try await fixture.store.createConversation()

        let outcome = try await fixture.store.send("q", in: convo.id, using: ScriptedDriver(saying: "a"))

        #expect(outcome == .completed(Fix.stopInfo))
        let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
        #expect(problems.isEmpty, "\(problems)")
    }
}

/// §10.4's chaos suite, made **deterministic** (D26): every enumerable
/// cancellation point of every scripted shape, crossed with both stop
/// mechanisms. Fixture scripts are tiny, so this is exhaustive rather than
/// sampled — no seed, no flake, and a failure reproduces by re-running.
@Suite("Store — cancellation chaos", .timeLimit(.minutes(1)))
struct StoreChaosTests {

    private enum Stop: CaseIterable {
        case storeCancel
        case taskCancel
    }

    /// The script bodies, with a park inserted at every position.
    private func shapes(parkingAt latch: Latch) -> [[ScriptedDriver.Step]] {
        let body: [ScriptedDriver.Step] = [
            .delta("one "),
            .toolRecord(ToolRecord(name: "lookupFold", status: .succeeded)),
            .delta("two "),
            .delta("three"),
        ]
        return (0...body.count).map { position in
            var script = body
            script.insert(.pause(latch), at: position)
            return script
        }
    }

    @Test("cancelling at every parked point yields exactly one terminal and a healthy log")
    func cancellationAtEveryPoint() async throws {
        for stop in Stop.allCases {
            for (position, script) in shapes(parkingAt: Latch()).enumerated() {
                // Each run gets its own latch, store and conversation, so a
                // failure names exactly one (mechanism, position) pair.
                let latch = Latch()
                let rescripted = script.map { step -> ScriptedDriver.Step in
                    if case .pause = step { .pause(latch) } else { step }
                }
                let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .zero, orAfterCharacters: 1))
                let convo = try await fixture.store.createConversation()

                let running = Task {
                    try await fixture.store.send("q", in: convo.id, using: ScriptedDriver(rescripted))
                }
                await latch.waitForArrival()

                switch stop {
                case .storeCancel: await fixture.store.cancelGeneration(in: convo.id)
                case .taskCancel: running.cancel()
                }

                let context = "\(stop) at position \(position)"
                #expect(try await running.value == .cancelled, "\(context): the verb returns .cancelled")

                let rows = try await fixture.rows(of: convo.id)
                let ends = rows.compactMap { row -> Outcome? in
                    guard case .decoded(let event) = row,
                          case .generationEnded(_, let outcome) = event.payload
                    else { return nil }
                    return outcome
                }
                #expect(ends == [.cancelled], "\(context): exactly one terminal (I3)")

                // Whatever the driver managed to emit before the stop is still
                // there — §7.5's partial retention, at every point.
                let emitted = script.prefix(position).compactMap { step -> String? in
                    if case .delta(let text) = step { text } else { nil }
                }.joined()
                #expect(
                    try await fixture.store.conversation(convo.id).activeMessages.last?.state
                        == .cancelled(partial: emitted),
                    "\(context): partial retained"
                )

                let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
                #expect(problems.isEmpty, "\(context): \(problems)")

                // The slot is free and the overlay input is empty again.
                #expect(await fixture.store.liveGenerations.isEmpty, "\(context): live set drained")
            }
        }
    }

    /// **P2's store-side half**, feeding M7: the live set is always a subset of
    /// *open* (started, un-terminated) generations. Checked while one is
    /// provably parked, which is the only moment the set is non-empty.
    @Test("the live set is exactly the open generation while one is in flight")
    func liveSetTracksOpenGenerations() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        let latch = Latch()

        #expect(await fixture.store.liveGenerations.isEmpty)

        let running = Task {
            try await fixture.store.send("q", in: convo.id, using: ScriptedDriver([.delta("a"), .pause(latch)]))
        }
        await latch.waitForArrival()

        let live = await fixture.store.liveGenerations
        let open = try await openGenerations(of: convo.id, in: fixture.backing)
        #expect(live == [Fix.genA])
        #expect(live.isSubset(of: open), "live ⊄ open would make overlay_live forge a .streaming bubble")

        await latch.release()
        _ = try await running.value
        #expect(await fixture.store.liveGenerations.isEmpty, "recovery is the overlay disappearing")
    }

    /// Generations that started and have not terminated, read from the log.
    private func openGenerations(
        of conversation: ConversationID,
        in backing: any PersistenceStore
    ) async throws -> Set<GenerationID> {
        var started: Set<GenerationID> = []
        for row in try await backing.events(in: conversation, from: 1) {
            guard case .decoded(let event) = row else { continue }
            switch event.payload {
            case .generationStarted(let generation, _, _, _): started.insert(generation)
            case .generationEnded(let generation, _): started.remove(generation)
            default: break
            }
        }
        return started
    }
}
