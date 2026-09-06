import Foundation

/// Audit record of one tool invocation inside a generation (SPEC §7.6).
/// Record, don't orchestrate: emitted after the invocation completes, which is
/// why it can carry `duration` — and why live "using tool…" UI is a session
/// concern, not a ledger one.
///
/// `argumentsJSON` / `resultJSON` populate only under the `.full` recording
/// policy; the default is `.metadataOnly` because tool results routinely
/// contain fetched sensitive data and the ledger outlives the session (§9).
public struct ToolRecord: Sendable, Codable, Equatable {

    public enum Status: String, Sendable, Codable {
        case succeeded
        case failed
    }

    public var name: String
    public var status: Status
    /// Wire form: integer milliseconds (ADR-001).
    public var duration: Duration?
    public var argumentsJSON: String?
    public var resultJSON: String?

    public init(
        name: String,
        status: Status,
        duration: Duration? = nil,
        argumentsJSON: String? = nil,
        resultJSON: String? = nil
    ) {
        self.name = name
        self.status = status
        self.duration = duration
        self.argumentsJSON = argumentsJSON
        self.resultJSON = resultJSON
    }

    private enum CodingKeys: String, CodingKey {
        case name, status, duration, argumentsJSON, resultJSON
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.status = try container.decode(Status.self, forKey: .status)
        self.duration = (try container.decodeIfPresent(Int64.self, forKey: .duration))
            .map(Duration.init(wireMilliseconds:))
        self.argumentsJSON = try container.decodeIfPresent(String.self, forKey: .argumentsJSON)
        self.resultJSON = try container.decodeIfPresent(String.self, forKey: .resultJSON)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(duration?.wireMilliseconds, forKey: .duration)
        try container.encodeIfPresent(argumentsJSON, forKey: .argumentsJSON)
        try container.encodeIfPresent(resultJSON, forKey: .resultJSON)
    }
}
