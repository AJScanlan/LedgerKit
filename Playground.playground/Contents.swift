@testable import LedgerKit
import PlaygroundSupport
import SwiftUI
import UIKit

// Note: passing a v4 UUID where v7 is desired is deliberately unpreventable —
// decode must accept whatever UUIDs are in historical logs, so v7-ness is a
// property of the generator (IDGenerator), not the type.

let initialUserMessageID = MessageID(UUID())
let botResponseMessageID = MessageID(UUID())
let erroredResponseMessageID = MessageID(UUID())
let followUpUserMessageID = MessageID(UUID())

// A spec-legal tree (§6.2: user messages are always .complete; §6.4: sibling
// assistant nodes arise from regenerate):
//
//     (virtual root)
//     └── initialUser ──┬── botResponse ── followUpUser
//                       └── erroredResponse   (failed regenerate, off-path)
let nodes: [MessageID: Message] = [
    initialUserMessageID: .init(
        id: initialUserMessageID,
        role: .user,
        children: [botResponseMessageID, erroredResponseMessageID],
        state: .complete(.init(text: "What's the capital of Ireland?")),
        timestamp: .now
    ),
    botResponseMessageID: .init(
        id: botResponseMessageID,
        role: .assistant,
        parent: initialUserMessageID,
        children: [followUpUserMessageID],
        state: .complete(.init(text: "Dublin")),
        timestamp: .now.advanced(by: 5)
    ),
    erroredResponseMessageID: .init(
        id: erroredResponseMessageID,
        role: .assistant,
        parent: initialUserMessageID,
        state: .failed(partial: "", .rateLimited(retryAfter: nil), .retryable(after: nil)),
        timestamp: .now.advanced(by: 10)
    ),
    followUpUserMessageID: .init(
        id: followUpUserMessageID,
        role: .user,
        parent: botResponseMessageID,
        state: .complete(.init(text: "Thank you")),
        timestamp: .now.advanced(by: 20)
    ),
]

let messages = MessageTree(nodes: nodes, rootChildren: [initialUserMessageID])
let activePath = [initialUserMessageID, botResponseMessageID, followUpUserMessageID]
let conversation = Conversation(id: .init(UUID()), messages: messages, activePath: activePath)

let view = ConversationView(conversation: conversation)
let hostingVC = UIHostingController(rootView: view)
PlaygroundPage.current.liveView = hostingVC
