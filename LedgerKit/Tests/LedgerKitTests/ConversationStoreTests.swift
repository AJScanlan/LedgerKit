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
    @Test("a conversation with no valid genesis is unknown")
    func genesislessLogIsUnknown() async throws {
        let backing = try SQLitePersistenceStore(.inMemory)
        var orphan = Log()
        orphan.append(.titleChanged("no genesis here"))
        _ = try await backing.append(orphan.records, to: orphan.conversation)

        let fixture = try StoreUnderTest(over: backing)

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

/// `ScriptedIdentifiers` mints message IDs in one stream, so a `send` takes two
/// of them: the user message first, then the assistant node.
private let firstUser = Fix.userA                  // 0x10
private let firstAssistant = MessageID(uuid(0x11)) // 0x11

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
@Suite("Store — single-flight and start atomicity")
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
    private static let everyDelta = DeltaFlushPolicy(interval: .zero, characterCount: 1)
    /// Nothing is ever due, so only the mandatory pre-terminal flush fires.
    private static let never = DeltaFlushPolicy(interval: .seconds(3600), characterCount: .max)

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
@Suite("Store — cache reentrancy")
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
