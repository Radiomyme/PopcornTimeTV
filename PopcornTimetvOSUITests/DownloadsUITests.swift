import XCTest

/// The Downloads tab: a row per download with its state said in words and
/// numbers, Select opening what can be done, Delete (asked first) removing
/// the row, Pause All / Resume All.
///
/// Runs on made-up downloads (`-PTDebugDownloadFixtures`): sparse files and
/// fake magnets, never resumed — pause and resume only change their state in
/// the app; Delete deletes their folders for real. `PT_UITEST_SHOTS=<folder>`
/// saves screenshots of the steps.
final class DownloadsUITests: XCTestCase {

    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!
    private static let focused = NSPredicate(format: "hasFocus == true")

    private static let halloween = "Downloads.Row.tt0077651"       // « downloading », 42 %
    private static let mobLand = "Downloads.Row.tt31510819-1-5"     // paused episode, 73 %
    private static let heart = "Downloads.Row.tt7526136"            // downloaded movie

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// Every row says where its download is; the badge counts the unfinished ones.
    func testTheRowsSayWhereEachDownloadIs() throws {
        launch()
        XCTAssertTrue(element(Self.halloween).waitForExistence(timeout: 20), "the Downloads page never showed")
        pause(1)
        snap("01-page")
        let downloading = element(Self.halloween).label
        XCTAssertTrue(downloading.contains("Halloween") && downloading.contains("42%") && downloading.contains("/s")
                      && downloading.contains("left") && downloading.contains(" of "), "Halloween: « \(downloading) »")
        let paused = element(Self.mobLand).label
        XCTAssertTrue(paused.contains("MobLand") && paused.contains("S1 E5") && paused.contains("Paused · 73%"), "MobLand: « \(paused) »")
        let failed = element("Downloads.Row.tt38515310").label
        XCTAssertTrue(failed.contains("Failed — There is not enough space"), "the failed download: « \(failed) »")
        XCTAssertTrue(element(Self.heart).exists, "the downloaded movie is not listed")
        XCTAssertTrue(element("Downloads.Storage").exists, "the space the downloads take is not said")
        XCTAssertTrue(element("Downloads.PauseAll").exists, "no Pause All while a download runs")
    }

    /// Select opens the row's actions; Delete asks, the focus on Cancel; the
    /// row goes once confirmed.
    func testSelectOpensTheActionsAndDeleteRemovesTheRow() throws {
        launch()
        XCTAssertTrue(element(Self.halloween).waitForExistence(timeout: 20), "the Downloads page never showed")
        pause(1)
        try focus(Self.halloween)
        remote.press(.select)
        XCTAssertTrue(element("Settings.Picker").waitForExistence(timeout: 5), "Select did not open the actions")
        XCTAssertTrue(app.buttons["Pause"].exists && app.buttons["Delete"].exists, "a running download offers Pause and Delete")
        snap("02-actions-downloading")
        remote.press(.menu)
        XCTAssertTrue(element("Settings.Picker").waitForNonExistence(timeout: 5), "Menu did not close the actions")

        try focus(Self.heart)
        remote.press(.select)
        XCTAssertTrue(element("Settings.Picker").waitForExistence(timeout: 5), "Select did not open the actions")
        XCTAssertTrue(app.buttons["Play"].exists && app.buttons["Delete"].exists, "a downloaded movie offers Play and Delete")
        remote.press(.down)
        pause(0.6)
        XCTAssertEqual(focusedLabel, "Delete")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Delete Download"].waitForExistence(timeout: 5), "Delete did not ask first")
        pause(0.8)
        XCTAssertEqual(focusedLabel, "Cancel", "the question does not start on Cancel")
        snap("03-delete-question")
        remote.press(.up)
        pause(0.6)
        remote.press(.select)
        XCTAssertTrue(element("Settings.Picker").waitForNonExistence(timeout: 5), "the sheet stayed after Delete")
        XCTAssertTrue(element(Self.heart).waitForNonExistence(timeout: 6), "the deleted download is still listed")
        snap("04-after-delete")
    }

    /// Pause All pauses what runs (the button becomes Resume All), Resume All
    /// starts them again.
    func testPauseAllAndResumeAll() throws {
        launch()
        XCTAssertTrue(element("Downloads.PauseAll").waitForExistence(timeout: 20), "no Pause All")
        pause(1)
        try focus("Downloads.PauseAll")
        remote.press(.select)
        XCTAssertTrue(element("Downloads.ResumeAll").waitForExistence(timeout: 5), "Pause All did not turn into Resume All")
        XCTAssertTrue(element(Self.halloween).label.contains("Paused · 42%"), "Halloween: « \(element(Self.halloween).label) »")
        snap("05-all-paused")
        pause(0.8)
        try focus("Downloads.ResumeAll")
        remote.press(.select)
        XCTAssertTrue(element("Downloads.PauseAll").waitForExistence(timeout: 5), "Resume All did not turn into Pause All")
        XCTAssertFalse(element(Self.mobLand).label.contains("Paused"), "MobLand did not resume: « \(element(Self.mobLand).label) »")
    }

    // MARK: Helpers

    private func launch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-tosAccepted", "YES",
            "-lastWhatsNewVersion", "99",
            "-themeSongVolume", "0",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-PTDebugLibraryInMemory", "YES",
            "-PTDebugHomeFixtures", Self.fixtures,
            "-PTDebugHomeDryRunPlay", "YES",
            "-PTDebugDownloadFixtures", "YES",
            "-PTDebugOpenURL", "popcorntime://tab/downloads",
        ]
        app.launch()
        self.app = app
    }

    private static var fixtures: String {
        if let folder = ProcessInfo.processInfo.environment["PT_UITEST_HOME_FIXTURES"], !folder.isEmpty { return folder }
        return URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PopcornTimeTests/Fixtures/Home").path
    }

    /// Moves the focus onto `identifier` with the arrows (down first, from
    /// the tab bar or a row above, then up).
    private func focus(_ identifier: String) throws {
        for direction in [XCUIRemote.Button.down, .up] {
            for _ in 0..<10 {
                if focusedIdentifier == identifier { return }
                remote.press(direction)
                pause(0.5)
            }
        }
        if focusedIdentifier == identifier { return }
        XCTFail("the focus never reached \(identifier) (it is on \(focusedIdentifier))")
        throw XCTSkip("focus")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private var focusedElement: XCUIElement {
        app.descendants(matching: .any).matching(Self.focused).firstMatch
    }

    private var focusedIdentifier: String {
        let focused = focusedElement
        return focused.exists ? focused.identifier : "none"
    }

    private var focusedLabel: String {
        let focused = focusedElement
        return focused.exists ? focused.label : "none"
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ step: String) {
        guard let folder = ProcessInfo.processInfo.environment["PT_UITEST_SHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("downloads-\(step).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
