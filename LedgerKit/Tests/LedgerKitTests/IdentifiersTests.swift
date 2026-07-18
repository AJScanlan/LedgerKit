import Foundation
import Testing

@testable import LedgerKit

@Suite("Identifiers")
struct IdentifiersTests {

    private let uuid = UUID(uuidString: "019F7285-D000-7000-8021-9FB669E8F58E")!

    @Test("Encodes as a bare UUID string, not a wrapper object")
    func encodesAsBareString() throws {
        struct Envelope: Codable { let id: EventID }

        let json = String(
            decoding: try JSONEncoder().encode(Envelope(id: EventID(uuid))),
            as: UTF8.self
        )

        #expect(json == #"{"id":"019F7285-D000-7000-8021-9FB669E8F58E"}"#)
    }

    @Test("Round-trips through Codable")
    func roundTrips() throws {
        struct Envelope: Codable, Equatable {
            let event: EventID
            let conversation: ConversationID
            let message: MessageID
            let generation: GenerationID
        }

        let original = Envelope(
            event: EventID(uuid),
            conversation: ConversationID(UUID()),
            message: MessageID(UUID()),
            generation: GenerationID(UUID())
        )
        let decoded = try JSONDecoder().decode(
            Envelope.self, from: try JSONEncoder().encode(original)
        )

        #expect(decoded == original)
    }

    @Test("Description is the plain UUID string, for log dumps")
    func descriptionIsReadable() {
        #expect(EventID(uuid).description == "019F7285-D000-7000-8021-9FB669E8F58E")
    }

    @Test("Same UUID in two ID types are not interchangeable values")
    func distinctIdentityPerType() {
        // I7 pairs a MessageID with a GenerationID; they must never collide in
        // a dictionary keyed by one of them.
        var seen: Set<MessageID> = []
        seen.insert(MessageID(uuid))

        #expect(seen.contains(MessageID(uuid)))
        // GenerationID(uuid) is not even expressible as a lookup here — that is
        // the point. This test documents the intent; the compiler enforces it.
    }
}
