import Foundation

/// How much of a tool invocation reaches the ledger (SPEC §7.6).
///
/// ```swift
/// let driver = GenerationDriver(model: model, descriptor: descriptor, toolRecording: .full)
/// ```
///
/// **The default is `.metadataOnly`, and the asymmetry is deliberate.** Tool
/// results routinely contain fetched sensitive data — a calendar, a mailbox, a
/// medical record — and **the ledger outlives the session** (§9 privacy). An
/// opt-out default would silently persist that data for every app that never
/// thought about it, so recording arguments and results is something an app
/// says *yes* to.
///
/// The cost of that default is owned rather than hidden: under `.metadataOnly`
/// the outputs were never retained, so a rebuilt session **cannot** be given
/// prior tool results (§7.1's fidelity classes, N11). Post-crash regeneration
/// can therefore differ from what the live session would have produced. The
/// audit trail outlives the session's memory of it — which is the right trade
/// for a durable log, and is stated in §7.1 rather than discovered.
///
/// A struct with factories rather than an `enum`, per D12: nobody switches over
/// a recording policy — it is handed to a driver and read only inside it — while
/// the set of things one might configure is certain to grow (per-tool rules,
/// redaction). As an enum each of those reshapes the type; as a struct each is
/// additive, and call sites read identically either way.
public struct ToolRecordingPolicy: Sendable, Equatable {

    /// The internal shape the driver switches over — the "enum within, struct
    /// without" asymmetry D12 describes.
    enum Level: Sendable, Equatable {
        case off
        case metadataOnly
        case full
    }

    let level: Level

    private init(_ level: Level) {
        self.level = level
    }

    /// Name, status and duration — **the default** (§7.6).
    ///
    /// Enough to answer "which tools ran, did they work, how slow were they"
    /// without persisting anything the tool fetched.
    public static let metadataOnly = Self(.metadataOnly)

    /// Adds `argumentsJSON` and `resultJSON` to every record.
    ///
    /// Opt-in because these are the fields that carry fetched content into a
    /// durable log. Worth it for an audit-first app, or one that intends to
    /// replay tool exchanges — but note that v0.1 records them as *audit* and
    /// does not reconstruct transcript entries from them (§7.1, a v0.2 item).
    public static let full = Self(.full)

    /// Records nothing. Tools still execute — the framework runs them inside the
    /// session and LedgerKit only ever observed them (§7.6, "record, don't
    /// orchestrate") — so this changes the ledger, never the generation.
    public static let off = Self(.off)

    /// Whether an invocation is recorded at all.
    var recordsInvocations: Bool { level != .off }

    /// Whether arguments and results ride along.
    var recordsPayloads: Bool { level == .full }
}
