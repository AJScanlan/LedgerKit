import LedgerKit
import SwiftUI

public struct ConversationView: View {
    let conversation: Conversation

    public init(conversation: Conversation) {
        self.conversation = conversation
    }

    public var body: some View {
//        ForEach(conversation.activePath, id: \.self) { id in
//            if let message = conversation.messages[id] {
//                Text(content(for: message))
//            }
//        }
        
        ForEach(conversation.activeMessages) { message in
            Text(content(for: message))
            if conversation.messages.siblings(of: message.id).isEmpty == false {
                // TODO: Show switcher
            }
        }
    }

    private func content(for message: Message) -> String {
        let role = switch message.role {
        case .user: "USER"
        case .assistant: "BOT"
        }

        let body = switch message.state {
        case .complete(let content): content.text
        default: "NOT HANDLED"
        }

        return "\(role): \(body)"
    }
}
