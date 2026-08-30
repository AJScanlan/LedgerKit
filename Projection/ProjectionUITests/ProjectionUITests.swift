import XCTest

// M8 Phase 2's drive-through: the whole loop, asserted at every step.
//
// **This is the automated half of the review gate.** Phase 3 records the hero
// GIF by hand, and a person watching is the final word — but a person watching
// notices what is *ugly*, not what is *absent*, and the sequence below is long
// enough that a missing step is easy to miss. It also means the flow the GIF
// depends on is checked before the camera is set up rather than during.
//
// It runs against `ScriptedLanguageModel` and a throwaway database, selected by
// the `--uitest` launch argument. That is tenet 5 reaching the app layer: no
// Apple Intelligence eligibility, no network, no dependence on what a model
// happens to say today — so a failure here is always the app's fault, which is
// the only kind of failure worth a test.
//
// ⚠️ **The assertions key on accessibility labels**, which is why they read as
// English. Those labels were added for VoiceOver; that they turned out to be the
// test's vocabulary is a fair argument for adding them in the first place.

final class ProjectionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()
        return app
    }

    /// Create → send → stream → complete → regenerate → switch branch → delete.
    @MainActor
    func testTheWholeLoop() throws {
        let app = launchApp()

        // ── The empty state ──────────────────────────────────────────────────
        // A fresh install, guaranteed fresh because the store is per-launch.
        let newConversation = app.buttons["New conversation"].firstMatch
        XCTAssertTrue(newConversation.waitForExistence(timeout: 10),
                      "a fresh install should offer to start a conversation")
        newConversation.tap()

        // ── Send ─────────────────────────────────────────────────────────────
        let composer = app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Name three folds")

        let send = app.buttons["Send"]
        XCTAssertTrue(send.isEnabled, "a non-empty draft should enable Send")
        send.tap()

        // ── Streaming ────────────────────────────────────────────────────────
        // `.streaming` is the one state no fold of any log can produce (§6.2),
        // so observing it at all is evidence the live overlay is working — not
        // merely that text arrived.
        let stop = app.buttons["Stop generating"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5),
                      "the composer should offer Stop while a generation is live")

        // ── Completion ───────────────────────────────────────────────────────
        // Regenerate appears only on a settled assistant message, so its arrival
        // is how the test knows the terminal landed.
        let regenerate = app.buttons["Regenerate"].firstMatch
        XCTAssertTrue(regenerate.waitForExistence(timeout: 30),
                      "the generation should reach a terminal and offer Regenerate")
        XCTAssertFalse(stop.exists, "Stop should retire with the generation")

        // ── Regenerate, and the branch it creates ────────────────────────────
        // §6.4's regenerate-as-sibling, which is the mechanism DoD-1's hero GIF
        // is about: the previous answer is not overwritten, it becomes a version.
        regenerate.tap()
        let pager = app.otherElements["Version 2 of 2"]
        XCTAssertTrue(pager.waitForExistence(timeout: 30),
                      "regenerating should produce a second version, not replace the first")

        // ── Switch back ──────────────────────────────────────────────────────
        let previous = app.buttons["Previous version"].firstMatch
        XCTAssertTrue(previous.exists, "the earlier version should be reachable")
        previous.tap()
        XCTAssertTrue(app.otherElements["Version 1 of 2"].waitForExistence(timeout: 5),
                      "switching branches should move the active path back")

        // ── Delete ───────────────────────────────────────────────────────────
        // §9's delete is irreversible and out-of-band; the projection is *told*
        // rather than left to infer it from a failed read (rev 10), and the
        // detail screen pops itself. Getting back to an empty list is the proof.
        app.buttons["Projection"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New conversation,'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the conversation should be listed")
        row.press(forDuration: 1.0)

        app.buttons["Delete"].firstMatch.tap()
        // The confirmation, because deleting a conversation cannot be undone.
        app.buttons["Delete"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["No conversations"].waitForExistence(timeout: 10),
                      "deleting the only conversation should return the empty state")
    }

    /// Renaming, and the fact that the *list* learns about it.
    ///
    /// Worth its own test because the interesting claim is not that a title can
    /// be typed — it is that nothing in the app holds a copy of it. The row
    /// updates because `titleChanged` is a non-delta append, so it moves the §9
    /// index, which the list projection re-reads. Tenet 2, checkable in five
    /// seconds.
    @MainActor
    func testRenamingReachesTheList() throws {
        let app = launchApp()

        let newConversation = app.buttons["New conversation"].firstMatch
        XCTAssertTrue(newConversation.waitForExistence(timeout: 10))
        newConversation.tap()

        app.buttons["Conversation"].firstMatch.tap()
        app.buttons["Rename…"].firstMatch.tap()

        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Origami notes")
        app.buttons["Rename"].firstMatch.tap()

        app.buttons["Projection"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Origami notes'")).firstMatch
                .waitForExistence(timeout: 5),
            "the list reads the index, so a rename should reach it without anyone refreshing"
        )
    }
}
