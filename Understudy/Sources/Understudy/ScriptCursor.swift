import Foundation
import Synchronization

/// Hands out scripts in order, and decides what happens when they run out.
///
/// Split out of the model deliberately. The policy is pure bookkeeping over
/// values that have nothing to do with Foundation Models, so keeping it here —
/// where the platform floor is low — is what lets ``ScriptExhaustion`` be
/// *executed* in tests today rather than only compiled. A rule that decides
/// what a double does when a test over-asks is worth more than a rule that
/// merely type-checks.
final class ScriptCursor: Sendable {

    let scripts: [Script]
    let exhaustion: ScriptExhaustion

    private let position = Mutex(0)

    init(scripts: [Script], exhaustion: ScriptExhaustion) {
        self.scripts = scripts
        self.exhaustion = exhaustion
    }

    /// How many scripts have been handed out.
    var served: Int {
        position.withLock { $0 }
    }

    /// The next script, advancing the cursor.
    func next() throws -> Script {
        try position.withLock { position in
            let index = position
            position += 1

            if index < scripts.count { return scripts[index] }

            switch exhaustion.policy {
            case .fail:
                throw ScriptExhausted(scriptCount: scripts.count, requestNumber: index + 1)
            case .repeatLast:
                guard let last = scripts.last else {
                    throw ScriptExhausted(scriptCount: 0, requestNumber: index + 1)
                }
                return last
            case .loop:
                guard !scripts.isEmpty else {
                    throw ScriptExhausted(scriptCount: 0, requestNumber: index + 1)
                }
                return scripts[index % scripts.count]
            }
        }
    }
}
