import Foundation
@testable import LedgerKit

/// A deterministic, human-readable rendering of a reduced log — the expected
/// half of an on-disk corpus fixture (SPEC §10.2).
///
/// **Renders `FoldedState`, not `Conversation`, and that is load-bearing.** The
/// folded layer is everything the *log* determines; classification additionally
/// takes a `RecoverabilityMapping`, and §8 explicitly wants mapping fixes to
/// land and retroactively upgrade affordances. Freezing classified state would
/// therefore make every legitimate §8 improvement break every frozen fixture —
/// pressure to "fix" the corpus, which is precisely how a frozen corpus stops
/// meaning anything. Folded state is what I1's first half promises is stable
/// forever, so it is what this format commits to.
///
/// **Nothing here renders via `description` or reflection.** ADR-001 declares
/// diagnostic prose non-contractual and free to reword, and `String(describing:)`
/// on an enum is a compiler implementation detail. A format frozen forever can
/// depend on neither, so every rendering below is an explicit exhaustive switch
/// over *case names* — which are the contract, and which a compiler error forces
/// someone to confront when the inventory grows.
enum StateDump {

    static func render(_ state: FoldedState) -> String {
        var lines: [String] = [
            "conversation \(state.id)",
            "genesis \(state.hasGenesis ? "yes" : "no")",
            "title \(quoted(state.title))",
            "instructions \(quoted(state.instructions))",
            "path \(state.activePath.isEmpty ? "—" : state.activePath.map { "\($0)" }.joined(separator: " > "))",
            "",
            "messages",
        ]

        var visited: Set<MessageID> = []
        // Explicit stack rather than recursion: house style for anything walking
        // tree depth, which tracks message count in a linear conversation.
        var stack: [(id: MessageID, depth: Int)] = state.rootChildren.reversed().map { ($0, 0) }

        while let (id, depth) = stack.popLast() {
            guard let message = state.messages[id], visited.insert(id).inserted else { continue }
            lines.append(describe(message, depth: depth))
            stack.append(contentsOf: message.children.reversed().map { ($0, depth + 1) })
        }

        // A node the tree cannot reach is impossible in v0.1 — nothing removes
        // messages — but rendering it loudly beats rendering nothing, since the
        // alternative is a fixture that silently loses state.
        let unreachable = state.messages.keys.filter { !visited.contains($0) }.sorted { "\($0)" < "\($1)" }
        if !unreachable.isEmpty {
            lines.append("")
            lines.append("unreachable")
            for id in unreachable {
                if let message = state.messages[id] { lines.append(describe(message, depth: 0)) }
            }
        }

        lines.append("")
        lines.append("diagnostics")
        if state.diagnostics.isEmpty {
            lines.append("  none")
        } else {
            for diagnostic in state.diagnostics {
                let identity = diagnostic.eventID.map { "\($0)" } ?? "—"
                lines.append("  seq \(diagnostic.sequence) \(identity) \(describe(diagnostic.reason))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Messages

    private static func describe(_ message: FoldedMessage, depth: Int) -> String {
        var parts = [
            String(repeating: "  ", count: depth + 1) + "\(message.id)",
            message.role.rawValue,
            describe(message.state),
        ]
        if let generation = message.generationID { parts.append("gen=\(generation)") }
        if let model = message.model {
            parts.append("model=\(model.provider)/\(model.model)/\(model.version ?? "—")")
        }
        parts.append("at=\(WireDate.string(from: message.timestamp))")
        if let terminal = message.terminalTimestamp {
            parts.append("ended=\(WireDate.string(from: terminal))")
        }
        if let stop = message.stopInfo {
            parts.append(
                "stop=[\(stop.stopReason ?? "—") in=\(stop.usage?.inputTokens.map(String.init) ?? "—")"
                    + " out=\(stop.usage?.outputTokens.map(String.init) ?? "—")"
                    + " resolved=\(stop.resolvedModelID ?? "—")]"
            )
        }
        for record in message.toolRecords {
            parts.append("tool=[\(record.name) \(record.status.rawValue)"
                + " \(record.duration.map { "\($0.wireMilliseconds)ms" } ?? "—")"
                + " args=\(quoted(record.argumentsJSON)) result=\(quoted(record.resultJSON))]")
        }
        return parts.joined(separator: " ")
    }

    private static func describe(_ state: FoldedMessageState) -> String {
        switch state {
        case .complete(let content): "complete \(quoted(content.text))"
        case .open(let partial): "open \(quoted(partial))"
        case .cancelled(let partial): "cancelled \(quoted(partial))"
        case .failed(let partial, let error): "failed \(quoted(partial)) \(describe(error))"
        }
    }

    // MARK: Errors

    private static func describe(_ error: GenerationError) -> String {
        switch error {
        case .modelUnavailable(let reason):
            "modelUnavailable(\(reason.rawValue))"
        case .contextSizeExceeded(let contextSize, let tokenCount):
            "contextSizeExceeded(size=\(contextSize.map(String.init) ?? "—")"
                + " tokens=\(tokenCount.map(String.init) ?? "—"))"
        case .guardrailViolation:
            "guardrailViolation"
        case .refusal:
            "refusal"
        case .unsupported(let feature):
            "unsupported(\(feature.rawValue))"
        case .rateLimited(let retryAfter):
            "rateLimited(\(retryAfter.map { "\($0.wireMilliseconds)ms" } ?? "—"))"
        case .providerFailure(let status, let code, let message):
            "providerFailure(status=\(status.map(String.init) ?? "—")"
                + " code=\(quoted(code)) message=\(quoted(message)))"
        case .transport(let failure):
            "transport(\(failure.rawValue))"
        case .unrecognized(let description):
            "unrecognized(\(quoted(description)))"
        }
    }

    // MARK: Diagnostics

    /// §6.6's inventory, rendered by *case*. Exhaustive on purpose: a new
    /// quarantine condition must not be able to reach a frozen fixture without
    /// someone deciding how it appears.
    private static func describe(_ reason: QuarantineReason) -> String {
        switch reason {
        case .undecodableEnvelope: "undecodableEnvelope"
        case .unknownPayloadKind(let kind): "unknownPayloadKind(\(quoted(kind)))"
        case .foreignConversation(let found): "foreignConversation(\(found))"
        case .beforeGenesis: "beforeGenesis"
        case .duplicateGenesis: "duplicateGenesis"
        case .unknownParent(let parent): "unknownParent(\(parent))"
        case .messageIDAlreadyUsed(let id): "messageIDAlreadyUsed(\(id))"
        case .additionalRootMessage(let id): "additionalRootMessage(\(id))"
        case .unknownEditTarget(let id): "unknownEditTarget(\(id))"
        case .editTargetNotUser(let id): "editTargetNotUser(\(id))"
        case .generationIDAlreadyUsed(let id): "generationIDAlreadyUsed(\(id))"
        case .unknownGeneration(let id): "unknownGeneration(\(id))"
        case .generationAlreadyTerminated(let id): "generationAlreadyTerminated(\(id))"
        case .duplicateTerminal(let id): "duplicateTerminal(\(id))"
        case .unknownPathEndpoint(let id): "unknownPathEndpoint(\(id))"
        case .sequenceGap(let missing): "sequenceGap(\(missing.lowerBound)...\(missing.upperBound))"
        }
    }

    private static func quoted(_ value: String?) -> String {
        guard let value else { return "—" }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
