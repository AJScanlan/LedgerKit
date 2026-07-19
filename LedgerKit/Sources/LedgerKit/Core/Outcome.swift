import Foundation

/// How a generation ended (SPEC §6.1). Every generation reaches exactly one
/// terminal outcome (I3) — or none, in which case the reducer derives
/// `.interrupted` (I5). There is deliberately no `Outcome.interrupted`:
/// interruption is the *absence* of a terminal and cannot be written to a log.
///
/// Decode note: within its `.failed` case the nested `GenerationError` decodes
/// tolerantly — an unknown error discriminator degrades to `.unrecognized`
/// rather than throwing (SPEC §6.6 row 3). An unknown *outcome* discriminator
/// throws here and is caught by `Payload`'s `generationEnded` branch, which
/// applies the same degradation. Both layers exist so a v0.2 log renders
/// historical failures as *failures* on v0.1 readers, never as fake crashes.
public enum Outcome: Sendable, Equatable {
    /// Usage, stop reason, resolved model identity (SPEC §7.7–7.8).
    case completed(StopInfo)
    case failed(GenerationError)
    /// User-initiated; partial content retained (SPEC §7.5).
    case cancelled
}

/// Completion metadata captured from the response (SPEC §7.7).
///
/// All fields optional: providers differ, and optional struct fields tolerate
/// additive change — enums are the evolution cliffs, structs are not.
/// ⚠️ Field names pinned against the iOS 27 beta at M6 (OQ5/OQ8); the shape is
/// stable.
public struct StopInfo: Sendable, Codable, Equatable {
    /// Why generation stopped, as reported by the provider.
    public var stopReason: String?
    public var usage: TokenUsage?
    /// The model identity the provider *reports* on the response — versus the
    /// *requested* `ModelDescriptor` on `generationStarted`. A provider
    /// silently upgrading its backend is visible as request ≠ resolved
    /// (SPEC §7.8).
    public var resolvedModelID: String?

    public init(stopReason: String? = nil, usage: TokenUsage? = nil, resolvedModelID: String? = nil) {
        self.stopReason = stopReason
        self.usage = usage
        self.resolvedModelID = resolvedModelID
    }

    private enum CodingKeys: String, CodingKey {
        case stopReason, usage, resolvedModelID
    }
}

/// Token accounting from `Response.usage` (SPEC §7.7). Spans input/output
/// including cached and reasoning tokens; per-message token/cost display is
/// table stakes for BYO-key apps.
public struct TokenUsage: Sendable, Codable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var reasoningTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cachedInputTokens, reasoningTokens
    }
}

/// The *requested* provider + model + version, well enough for branch-compare
/// across models (SPEC §7.8). Rides `generationStarted`; the resolved identity
/// lands in `StopInfo` at completion.
public struct ModelDescriptor: Sendable, Codable, Hashable {
    public var provider: String
    public var model: String
    public var version: String?

    public init(provider: String, model: String, version: String? = nil) {
        self.provider = provider
        self.model = model
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, version
    }
}

// MARK: - Wire coding

extension Outcome: Codable {
    private enum Kind: String {
        case completed, failed, cancelled
    }

    private enum CodingKeys: String, CodingKey {
        case kind, stopInfo, error
    }

    private struct TagProbe: Decodable {
        var kind: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown outcome kind: \(rawKind)"
            )
        }
        switch kind {
        case .completed:
            self = .completed(try container.decode(StopInfo.self, forKey: .stopInfo))
        case .failed:
            // Tolerant nested decode (SPEC §6.6 row 3): an unfamiliar error
            // written by a future LedgerKit stays a *failure* on this reader.
            do {
                self = .failed(try container.decode(GenerationError.self, forKey: .error))
            } catch {
                let tag = (try? container.decode(TagProbe.self, forKey: .error))?.kind ?? "<unreadable>"
                self = .failed(.unrecognized(description: "undecodable outcome: \(tag)"))
            }
        case .cancelled:
            self = .cancelled
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed(let stopInfo):
            try container.encode(Kind.completed.rawValue, forKey: .kind)
            try container.encode(stopInfo, forKey: .stopInfo)
        case .failed(let error):
            try container.encode(Kind.failed.rawValue, forKey: .kind)
            try container.encode(error, forKey: .error)
        case .cancelled:
            try container.encode(Kind.cancelled.rawValue, forKey: .kind)
        }
    }
}
