import SwiftUI

@main
struct ProjectionApp: App {
    var body: some Scene {
        WindowGroup {
            // The app deploys to 26 (matching the package floor — see CLAUDE.md's
            // "never bump a package floor to 27"), while `GenerationDriver` and
            // `ScriptedLanguageModel` are 27-only. So the gate lives here, once, and
            // everything below it can assume a 27 runtime.
            if #available(macOS 27.0, iOS 27.0, *) {
                StreamingPreview()
            } else {
                ContentUnavailableView(
                    "Needs iOS 27",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Foundation Models' session API is 27-only.")
                )
            }
        }
    }
}
