import LedgerKit
import SwiftUI

@main
struct ProjectionApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// **Two gates, and they fail for different reasons** — which is why they are two
/// views rather than one state machine.
///
/// The availability gate is a *build target* fact: the app deploys to 26
/// (matching the package floor — see CLAUDE.md's "never bump a package floor to
/// 27") while `GenerationDriver` and `ScriptedLanguageModel` are 27-only. It has
/// to be the outer one, because everything inside is a type that does not exist
/// below 27.
struct RootView: View {
    var body: some View {
        if #available(macOS 27.0, iOS 27.0, *) {
            LedgerRootView()
        } else {
            ContentUnavailableView(
                "Needs iOS 27",
                systemImage: "exclamationmark.triangle",
                description: Text("Foundation Models' session API is 27-only.")
            )
        }
    }
}

/// Opens the store once, and says why if it cannot — a *runtime* fact, distinct
/// from the OS one above: "this device's disk is unhappy today" is a different
/// sentence from "this OS cannot run the app", and collapsing them would tell a
/// user on iOS 26 that their storage failed.
@available(macOS 27.0, iOS 27.0, *)
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
