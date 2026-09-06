import Foundation
import Testing
@testable import LedgerKit

// The discriminator registry, enforced (ADR-001 D-3 — the last of that ADR's
// open questions, closed at M4 Phase 4).
//
// ADR-001 asks whether "tags are never reused" is a convention, a test over a
// checked-in manifest, or a compile-time construct. It is now the middle one:
// `Registry/tags.json` holds every tag and field key the wire format has ever
// used, and this suite checks it against what the codecs actually produce — in
// **both** directions, which is what makes it more than documentation.
//
// What each direction catches:
//
// - **Registered but not observed** → a tag or key was renamed or deleted in
//   code. The manifest is the only place that remembers it existed.
// - **Observed but not registered** → a tag or key was added without a registry
//   entry, i.e. a permanent wire commitment made by accident.
// - **Reserved and live again** → the one thing ADR-001 forbids outright.
//
// The observed side comes from `Wire`'s inventories (`WireFormatTests.swift`),
// which name every case explicitly. That coupling is deliberate and is the third
// leg of the check: **deleting a case from an enum fails to compile the
// inventory**, so removal cannot slip past as "nothing observed it anymore".
//
// Known limit, stated rather than papered over: for the raw-value enums
// (`ModelUnavailability`, `UnsupportedFeature`, `TransportFailure`,
// `ToolRecord.Status`) Swift offers no reflection over cases, so *additions* are
// caught only because every case appears in an inventory that a reviewer of a new
// case would have to touch. A `CaseIterable` conformance would close that, and is
// deliberately not added: it would be public API bought for a test.

/// `Registry/tags.json`, decoded.
///
/// Deliberately a dumb value type. The manifest's job is to be diffable by a
/// human reviewing a wire change, so it holds strings, not behaviour.
struct TagRegistry: Decodable {

    struct ReservedTag: Decodable, Equatable {
        var level: String
        var tag: String
        /// The revision that retired it, so a reader meeting a strange tag in an
        /// old log never has to reconstruct this from git history.
        var removed: String
        /// Whether decoding old bytes needs an upcaster. `false` is only honest
        /// when no released version ever wrote the tag.
        var upcaster: Bool
        var why: String
    }

    /// The one key that is a discriminator at every tagged level (R-1), and
    /// therefore the one name no payload field may ever take.
    var discriminatorKey: String
    var tags: [String: [String]]
    var reserved: [ReservedTag]
    var fieldKeys: [String: [String]]

    static func load() throws -> TagRegistry {
        let url = try #require(
            Bundle.module.url(forResource: "Registry", withExtension: nil)?
                .appendingPathComponent("tags.json"),
            "Registry/tags.json is not in the test bundle — check Package.swift resources"
        )
        return try JSONDecoder().decode(TagRegistry.self, from: Data(contentsOf: url))
    }

    func registeredTags(_ level: String) throws -> Set<String> {
        Set(try #require(tags[level], "no registered tags for level '\(level)'"))
    }

    func registeredFieldKeys(_ level: String) throws -> Set<String> {
        Set(try #require(fieldKeys[level], "no registered field keys for level '\(level)'"))
    }
}

/// What a level's encoded form actually contains: the discriminator it wrote and
/// the field keys beside it.
private struct Observed {
    var tags: Set<String> = []
    var fieldKeys: Set<String> = []

    /// - Parameter discriminator: `nil` for untagged levels (the envelope and the
    ///   nested structs), which have field keys but no `kind`.
    init<Value: Encodable>(_ values: [Value], discriminator: String?) throws {
        for value in values {
            let object = try Self.object(value)
            for (key, raw) in object {
                if key == discriminator {
                    tags.insert(try #require(raw as? String, "discriminator '\(key)' is not a string"))
                } else {
                    fieldKeys.insert(key)
                }
            }
        }
    }

    /// Through `WireJSON`, not a local encoder: the registry must describe the
    /// bytes the store writes, and an encoder configured here could differ from it
    /// (ADR-001 D-1's argument, applied to the inventory rather than to a fixture).
    static func object<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try WireJSON.encoder().encode(value)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "encoded to something that is not a JSON object"
        )
    }

    /// The string at `key` in each encoded value — how the nested raw-value enums
    /// are observed, since they encode as bare strings inside their parent rather
    /// than as tagged objects of their own.
    static func nestedStrings<Value: Encodable>(_ values: [Value], at key: String) throws -> Set<String> {
        var found: Set<String> = []
        for value in values {
            if let raw = try object(value)[key] as? String { found.insert(raw) }
        }
        return found
    }
}

@Suite("Discriminator registry (ADR-001 D-3)")
struct RegistryTests {

    private let registry: TagRegistry

    init() throws {
        self.registry = try TagRegistry.load()
    }

    // MARK: Tags

    @Test("payload kinds match the registry exactly")
    func payloadTags() throws {
        let observed = try Observed(Wire.allKinds, discriminator: registry.discriminatorKey)
        let registered = try registry.registeredTags("payload")
        #expect(observed.tags == registered)
    }

    @Test("outcome kinds match the registry exactly")
    func outcomeTags() throws {
        let observed = try Observed(Wire.allOutcomes, discriminator: registry.discriminatorKey)
        let registered = try registry.registeredTags("outcome")
        #expect(observed.tags == registered)
    }

    @Test("error kinds match the registry exactly")
    func errorTags() throws {
        let observed = try Observed(Wire.allErrors, discriminator: registry.discriminatorKey)
        let registered = try registry.registeredTags("error")
        #expect(observed.tags == registered)
    }

    @Test("the nested raw-value enums match the registry exactly")
    func nestedRawValueTags() throws {
        // These encode as bare strings under a named key rather than as tagged
        // objects, so they are observed through their parent's field — which is
        // also the only reason both directions are checkable at all for enums
        // Swift will not enumerate.
        let nested: [(level: String, key: String, observed: Set<String>)] = [
            ("modelUnavailability", "reason", try Observed.nestedStrings(Wire.allErrors, at: "reason")),
            ("unsupportedFeature", "feature", try Observed.nestedStrings(Wire.allErrors, at: "feature")),
            ("transportFailure", "failure", try Observed.nestedStrings(Wire.allErrors, at: "failure")),
            ("toolStatus", "status", try Observed.nestedStrings(Wire.allToolRecords, at: "status")),
        ]
        for (level, key, observed) in nested {
            let registered = try registry.registeredTags(level)
            #expect(observed == registered, "level '\(level)' (encoded under '\(key)')")
        }
    }

    @Test("every registered raw value still constructs its case")
    func rawValuesStillResolve() throws {
        // The complement of the test above, and the one that localizes a failure:
        // a rename shows up here as "the registry names a case this build does not
        // have", naming the tag, rather than as two sets that differ somewhere.
        for tag in try registry.registeredTags("modelUnavailability") {
            #expect(ModelUnavailability(rawValue: tag) != nil, "ModelUnavailability lost '\(tag)'")
        }
        for tag in try registry.registeredTags("unsupportedFeature") {
            #expect(UnsupportedFeature(rawValue: tag) != nil, "UnsupportedFeature lost '\(tag)'")
        }
        for tag in try registry.registeredTags("transportFailure") {
            #expect(TransportFailure(rawValue: tag) != nil, "TransportFailure lost '\(tag)'")
        }
        for tag in try registry.registeredTags("toolStatus") {
            #expect(ToolRecord.Status(rawValue: tag) != nil, "ToolRecord.Status lost '\(tag)'")
        }
    }

    // MARK: Field keys (R-2)

    @Test("every level's field keys match the registry exactly")
    func fieldKeys() throws {
        // R-2's consequence, enforced: "the field keys are wire contract alongside
        // the tags." A new field key is as permanent as a new tag, and this is what
        // makes adding one a deliberate act.
        //
        // Note the inventories must keep every optional *populated* somewhere, or a
        // key silently drops out of the observed set — which is why `Wire.allErrors`
        // carries both the populated and the nil form of the same case.
let levels: [(level: String, observed: Set<String>)] = [
            ("envelope", try Observed([Wire.record], discriminator: nil).fieldKeys),
            ("payload", try Observed(Wire.allKinds, discriminator: registry.discriminatorKey).fieldKeys),
            ("outcome", try Observed(Wire.allOutcomes, discriminator: registry.discriminatorKey).fieldKeys),
            ("error", try Observed(Wire.allErrors, discriminator: registry.discriminatorKey).fieldKeys),
            ("toolRecord", try Observed(Wire.allToolRecords, discriminator: nil).fieldKeys),
            ("stopInfo", try Observed([Wire.stopInfo], discriminator: nil).fieldKeys),
            ("tokenUsage", try Observed([try #require(Wire.stopInfo.usage)], discriminator: nil).fieldKeys),
            ("modelDescriptor", try Observed([Wire.model], discriminator: nil).fieldKeys),
        ]

        for (level, observed) in levels {
            let registered = try registry.registeredFieldKeys(level)
            #expect(observed == registered, "field keys disagree at level '\(level)'")
        }
    }

    @Test("no field key is named 'kind' (R-1's reserved key)")
    func discriminatorIsNotAFieldName() throws {
        // R-1 chose flat tagged objects, which buys readable fixtures and a trivial
        // discriminator probe — at the cost of one reserved word, forever. The
        // registry is where that cost is policed, because the failure mode is a
        // payload field that shadows the tag and makes a whole level undecodable.
        for (level, keys) in registry.fieldKeys.sorted(by: { $0.key < $1.key }) {
            #expect(
                !keys.contains(registry.discriminatorKey),
                "'\(registry.discriminatorKey)' is reserved, but level '\(level)' registers it as a field"
            )
        }
    }

    // MARK: The reserved table

    @Test("reserved tags are not live at their level")
    func reservedTagsAreNotLive() throws {
        // Bookkeeping half: a retired tag must not reappear in the live inventory.
        for entry in registry.reserved {
            let live = try registry.registeredTags(entry.level)
            #expect(
                !live.contains(entry.tag),
                "'\(entry.tag)' is reserved (\(entry.removed)) but is live again at level '\(entry.level)'"
            )
        }
        // Non-vacuity: the table has an entry, so the loop above ran. Without this
        // the whole suite would pass on an empty reserved table, which is exactly
        // the state a careless "clean-up" would leave it in.
        #expect(registry.reserved.contains { $0.tag == "contextWindowExceeded" })
    }

    @Test("a reserved tag does not decode")
    func reservedTagsDoNotDecode() throws {
        // Behavioural half, and the sharper one: the bookkeeping test above passes
        // if someone teaches the *decoder* the old name while leaving the manifest
        // alone. This one does not.
        for entry in registry.reserved where entry.level == "error" {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    GenerationError.self,
                    from: Data(#"{"kind":"\#(entry.tag)"}"#.utf8)
                )
            }
        }
    }

    // MARK: The manifest itself

    @Test("the manifest is a plausible registry, not an empty shell")
    func manifestIsPopulated() throws {
        // Every check above compares two sets. Two *empty* sets are equal, so a
        // manifest gutted to `{}` — or an inventory that stopped enumerating —
        // would turn this suite green while enforcing nothing. These floors are
        // what makes the equality assertions mean something.
        let payloadTags = try registry.registeredTags("payload")
        let outcomeTags = try registry.registeredTags("outcome")
        let errorTags = try registry.registeredTags("error")
        let payloadKeys = try registry.registeredFieldKeys("payload")
        #expect(payloadTags.count == 10, "SPEC §6.1: exactly ten payload kinds")
        #expect(outcomeTags.count == 3)
        #expect(errorTags.count >= 9)
        #expect(payloadKeys.count >= 13)
        #expect(registry.discriminatorKey == "kind")
    }
}
