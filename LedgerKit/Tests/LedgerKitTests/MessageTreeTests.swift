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
            state: .complete(Content(text: "")),
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

    @Test("siblings exclude the message itself")
    func siblingsExcludeSelf() {
        #expect(tree.siblings(of: Self.response).map(\.id) == [Self.failedResponse])
        #expect(tree.siblings(of: Self.failedResponse).map(\.id) == [Self.response])
    }

    @Test("root-level messages have siblings via the virtual root (I6) — the edited-first-message case")
    func rootSiblingsViaVirtualRoot() {
        #expect(tree.siblings(of: Self.rootOriginal).map(\.id) == [Self.rootEdited])
        #expect(tree.siblings(of: Self.rootEdited).map(\.id) == [Self.rootOriginal])
    }

    @Test("a lone message has no siblings — the branch-switcher predicate is isEmpty")
    func loneMessageHasNoSiblings() {
        #expect(tree.siblings(of: Self.followUp).isEmpty)
        #expect(tree.siblings(of: Self.unknown).isEmpty)
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
