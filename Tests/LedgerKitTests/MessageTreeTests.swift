import Foundation
import Testing
@testable import LedgerKit

/// Read-API semantics over a hand-assembled tree (the reducer takes over
/// construction at M2). Shape under test — a conversation with both branch
/// kinds the spec makes legal (§6.4):
///
///     (virtual root)
///     ├── rootOriginal ──┬── response ── followUp
///     │                  └── failedResponse        (regenerate sibling, off-path)
///     └── rootEdited                               (root-level edit sibling, I6)
@Suite("MessageTree read API")
struct MessageTreeTests {
    static let rootOriginal = MessageID(UUID())
    static let rootEdited = MessageID(UUID())
    static let response = MessageID(UUID())
    static let failedResponse = MessageID(UUID())
    static let followUp = MessageID(UUID())
    static let unknown = MessageID(UUID())

    let tree = MessageTree(
        nodes: [
            rootOriginal: node(rootOriginal, role: .user, children: [response, failedResponse]),
            rootEdited: node(rootEdited, role: .user),
            response: node(response, role: .assistant, parent: rootOriginal, children: [followUp]),
            failedResponse: node(failedResponse, role: .assistant, parent: rootOriginal),
            followUp: node(followUp, role: .user, parent: response),
        ],
        rootChildren: [rootOriginal, rootEdited]
    )

    private static func node(
        _ id: MessageID,
        role: Role,
        parent: MessageID? = nil,
        children: [MessageID] = []
    ) -> Message {
        Message(
            id: id,
            role: role,
            parent: parent,
            children: children,
            state: .complete(MessageContent(text: "")),
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("subscript is Dictionary-shaped: message for known IDs, nil for unknown")
    func subscriptLookup() {
        #expect(tree[Self.response]?.role == .assistant)
        #expect(tree[Self.unknown] == nil)
    }

    @Test("children resolve in sibling order; unknown parents yield empty")
    func children() {
        #expect(tree.children(of: Self.rootOriginal).map(\.id) == [Self.response, Self.failedResponse])
        #expect(tree.children(of: Self.followUp).isEmpty)
        #expect(tree.children(of: Self.unknown).isEmpty)
    }

    @Test("versions include the message itself, in sibling order")
    func versionsAreInclusiveAndOrdered() {
        // Both orderings asserted from both members, because "inclusive" and
        // "ordered" are separable and only the pair pins the pager's display.
        #expect(tree.versions(of: Self.response).map(\.id) == [Self.response, Self.failedResponse])
        #expect(tree.versions(of: Self.failedResponse).map(\.id) == [Self.response, Self.failedResponse])
    }

    @Test("root-level messages have versions via the virtual root (I6) — the edited-first-message case")
    func rootVersionsViaVirtualRoot() {
        #expect(tree.versions(of: Self.rootOriginal).map(\.id) == [Self.rootOriginal, Self.rootEdited])
        #expect(tree.versions(of: Self.rootEdited).map(\.id) == [Self.rootOriginal, Self.rootEdited])
    }

    @Test("a lone message is its own only version — the pager predicate is count > 1")
    func loneMessageIsItsOwnOnlyVersion() {
        #expect(tree.versions(of: Self.followUp).map(\.id) == [Self.followUp])
        // The one case that is genuinely empty: an ID the tree does not hold.
        // Distinct from "one version", which is what a lone message has —
        // conflating them is how a pager ends up rendering `‹ 1 of 0 ›`.
        #expect(tree.versions(of: Self.unknown).isEmpty)
    }

    /// **The property that replaced `siblings == versions − self`, and is stronger
    /// than it was** (D64): a version set belongs to a *position*, not to the
    /// member you asked about. Every member of a group must therefore report the
    /// identical set.
    ///
    /// The old subtraction property could be satisfied by an implementation that
    /// computed the group differently per member — which is exactly the bug a
    /// pager would show as the index jumping when you page. This cannot.
    @Test("a version set is a property of the position: every member reports the same set")
    func versionsAreAPropertyOfThePosition() {
        var checked = 0
        for id in [Self.rootOriginal, Self.rootEdited, Self.response, Self.failedResponse, Self.followUp] {
            let group = tree.versions(of: id)
            #expect(group.contains { $0.id == id }, "\(id) must appear in its own version set")
            for member in group {
                #expect(
                    tree.versions(of: member.id).map(\.id) == group.map(\.id),
                    "\(member.id) reports a different set than \(id), which share a position"
                )
                checked += 1
            }
        }
        // Non-vacuity, bound on the measured value (2+2+2+2+1 = 9).
        #expect(checked == 9, "the sweep checked \(checked) pairs, which cannot be right")
    }

    @Test("dangling child references drop silently — absence, not error (I2 posture)")
    func danglingReferencesDrop() {
        let dangling = MessageTree(
            nodes: [Self.rootOriginal: Self.node(Self.rootOriginal, role: .user, children: [Self.unknown])],
            rootChildren: [Self.rootOriginal]
        )
        #expect(dangling.children(of: Self.rootOriginal).isEmpty)
    }

    @Test("Conversation.activeMessages resolves the path in order, dropping dangling entries")
    func activeMessages() {
        let conversation = Conversation(
            id: ConversationID(UUID()),
            messages: tree,
            activePath: [Self.rootOriginal, Self.response, Self.followUp, Self.unknown]
        )
        #expect(conversation.activeMessages.map(\.id) == [Self.rootOriginal, Self.response, Self.followUp])
    }
}
