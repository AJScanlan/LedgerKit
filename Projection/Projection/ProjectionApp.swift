import LedgerKit
import SwiftUI

@main
struct ProjectionApp: App {
    var body: some Scene {
        WindowGroup {
            LedgerRootView()
        }
    }
}

// **There was a second gate here until M9 (D70), and deleting it is the point.**
//
// The app used to deploy to 26 — matching the package floor — and then refuse to
// run below 27 at launch, because `GenerationDriver` and `ScriptedLanguageModel`
// are 27-only. So it shipped a build configuration it could not use, and the
// only thing the gate demonstrated was its own vacuity.
//
// ⚠️ **The packages stay at 26, and this changes nothing about that.** The
// question worth asking before moving the app was: if the app goes to 27, what
// still evidences the *packages'* 26 floor? Checked rather than assumed — the
// package builds do, and always did. SPM compiles LedgerKit at
// `arm64-apple-macos26.0` from the manifest's `.macOS(.v26)`, and the simulator
// tier at `arm64-apple-ios26.0-simulator`; both are commands CI already runs.
// The app was never the evidence, which is exactly why moving it costs nothing.
// Had the answer come out the other way, D70 would have been wrong.

/// Opens the store once, and says why if it cannot — a **runtime** fact.
///
/// This was the *inner* of two gates until D70 removed the outer OS one. The
/// distinction it drew still matters and is worth keeping written down: "this
/// device's disk is unhappy today" is a different sentence from "this OS cannot
/// run the app", and collapsing them would have told a user on iOS 26 that their
/// storage had failed. With the deployment target at 27 the second sentence is
/// no longer reachable, so only the honest one remains.
private struct LedgerRootView: View {

    @State private var state: OpenState = .opening

    var body: some View {
        Group {
            switch state {
            case .opening:
                ProgressView()
            case .ready(let model):
                ConversationListScreen(model: model)
            case .failed(let description):
                ContentUnavailableView(
                    "Could not open the ledger",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text(description)
                )
            }
        }
        .task {
            guard case .opening = state else { return }
            do {
                state = .ready(try AppModel())
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }

    /// A closed enum rather than an `AppModel?` beside a `String?`: three states
    /// with three screens, and the pair-of-optionals spelling can represent
    /// combinations none of them means. Tenet 1, applied to the app's own root.
    private enum OpenState {
        case opening
        case ready(AppModel)
        case failed(String)
    }
}
