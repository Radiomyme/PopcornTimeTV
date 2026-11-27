import XCTest

/// Profiles on the Apple TV: « Who's Watching? » at launch when the device
/// has more than one profile, a pick opening the Home of that profile, and
/// Settings › Switch Profile changing it — each profile with its own
/// Continue Watching; Menu on each of these screens; the editor's focus; a
/// link that comes while the question is up; Your Preferences.
///
/// Runs like `HomeUITests`: a DEBUG build, the Home fed from recorded
/// answers (`-PTDebugHomeFixtures`), the library and the profiles in memory
/// (`-PTDebugLibraryInMemory`; `-PTDebugProfiles Alex` adds a second
/// profile to the primary one, « Me »). `-PTDebugHomeResume` puts a movie
/// in progress into the profile picked first. `PT_UITEST_SHOTS=<folder>`
/// saves screenshots of the steps.
final class ProfilesUITests: XCTestCase {

    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!
    private static let focused = NSPredicate(format: "hasFocus == true")
    private static let resume = "tt0816692|Interstellar|0.42|169"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// One profile (every device until a second is made): no picker, the Home at once.
    func testOneProfileOpensTheHomeAtOnce() throws {
        launch([])
        XCTAssertTrue(element("Home.Hero").waitForExistence(timeout: 30), "the Home never showed")
        XCTAssertFalse(element("Profiles.Title").exists, "« Who's Watching? » with a single profile")
    }

    /// Two profiles: the picker first; « Me » gets the movie in progress;
    /// Settings › Switch Profile › Alex shows a Home without it; back to
    /// « Me », it is there again.
    func testThePickerAndSwitchingKeepEachProfilesContinueWatching() throws {
        launch(["-PTDebugProfiles", "Alex", "-PTDebugHomeResume", Self.resume])
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 20), "« Who's Watching? » never showed")
        XCTAssertTrue(element("Profiles.Profile.Me").exists && element("Profiles.Profile.Alex").exists, "the two profiles are not offered")
        XCTAssertFalse(element("Profiles.Cancel").exists, "the launch picker can be dismissed without a pick")
        pause(1.5)
        snap("1-who-is-watching")
        XCTAssertEqual(focusedIdentifier, "Profiles.Profile.Me", "the focus does not start on the profile in use")

        // « Me »: the movie in progress.
        remote.press(.select)
        let resumed = element("Home.Section.continueWatching").waitForExistence(timeout: 30)
        snap("2-me-home")
        XCTAssertTrue(resumed, "Me's Home has no Continue Watching")

        // Settings › Switch Profile › Alex.
        try switchProfile(to: "Alex", moves: 1)
        XCTAssertTrue(element("Home.Hero").waitForExistence(timeout: 30), "Alex's Home never showed")
        pause(3)
        snap("4-alex-home")
        XCTAssertFalse(element("Home.Section.continueWatching").exists, "Alex sees Me's Continue Watching")

        // Back to « Me »: the picker's focus starts on Alex, the profile in use.
        try switchProfile(to: "Me", moves: -1)
        XCTAssertTrue(element("Home.Section.continueWatching").waitForExistence(timeout: 30), "Me's Continue Watching is gone")
        snap("5-me-again")
    }

    /// A profile with a taste: « For You » on its Home; Settings › Profiles
    /// › Your Preferences, a sheet over Settings, says what it likes; its one
    /// focus is Reset Preferences, which empties it in place; Menu closes it
    /// and the row then reads « Nothing yet ».
    func testForYouAndYourPreferences() throws {
        launch(["-PTDebugTasteGenres", "Sci-Fi,Drama"])
        XCTAssertTrue(element("Home.Section.forYou").waitForExistence(timeout: 30), "no « For You » on the Home")
        pause(2)
        snap("6-for-you")

        try openSettingsRow("Settings.Row.profilePreferences")
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Taste.Title").waitForExistence(timeout: 10), "Your Preferences never showed")
        let genres = element("Profiles.Taste.Genres")
        XCTAssertTrue(genres.exists, "no genres learned")
        XCTAssertTrue(genres.label.contains("Drama"), "the genres: \(genres.label)")
        XCTAssertTrue(element("Settings.Row.profilePreferences").exists, "the sheet is not over Settings")
        pause(1)
        snap("7-your-preferences")
        XCTAssertEqual(focusedIdentifier, "Profiles.Taste.Reset", "the focus does not start on Reset")

        // The question in the card, its focus on Cancel; Menu cancels it.
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Taste.ResetCancel").waitForExistence(timeout: 10), "no question in the card")
        pause(1)
        snap("8-reset-confirm")
        XCTAssertEqual(focusedIdentifier, "Profiles.Taste.ResetCancel", "the question's focus is not on Cancel")
        remote.press(.menu)
        XCTAssertTrue(element("Profiles.Taste.Reset").waitForExistence(timeout: 10), "Menu did not cancel the question")
        XCTAssertTrue(element("Profiles.Taste.Title").exists, "Menu closed the sheet instead of the question")
        pause(1)
        XCTAssertEqual(focusedIdentifier, "Profiles.Taste.Reset", "the focus is not back on Reset")
        // Asked again: Reset Preferences is above Cancel.
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Taste.ResetConfirm").waitForExistence(timeout: 10), "no question in the card")
        pause(1)
        remote.press(.up)
        pause(0.8)
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Taste.Empty").waitForExistence(timeout: 10), "the preferences were not reset")
        XCTAssertFalse(element("Profiles.Taste.Reset").exists, "Reset is offered with nothing to reset")
        snap("9-your-preferences-empty")
        remote.press(.menu)
        XCTAssertTrue(element("Profiles.Taste.Title").waitForNonExistence(timeout: 10), "Your Preferences stayed")
        let row = element("Settings.Row.profilePreferences")
        XCTAssertTrue(row.label.contains("Nothing yet"), "the row still says what was learned: \(row.label)")
        XCTAssertEqual(focusedIdentifier, "Settings.Row.profilePreferences", "the focus left the row")
    }

    /// Menu on the launch question is the system's: it leaves the app for
    /// the Home Screen, as on any app's first screen.
    func testMenuOnTheLaunchPickerLeavesTheApp() throws {
        launch(["-PTDebugProfiles", "Alex"])
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 20), "« Who's Watching? » never showed")
        pause(1.5)
        // In Manage mode, Menu leaves it first.
        remote.press(.down)
        pause(0.8)
        XCTAssertEqual(focusedIdentifier, "Profiles.Manage", "Down did not reach Manage Profiles")
        remote.press(.select)
        pause(1)
        XCTAssertEqual(element("Profiles.Title").label, "Manage Profiles", "Manage mode did not start")
        remote.press(.menu)
        pause(1)
        XCTAssertEqual(element("Profiles.Title").label, "Who’s Watching?", "Menu did not leave Manage mode")
        XCTAssertEqual(app.state, .runningForeground, "Menu in Manage mode left the app")
        remote.press(.menu)
        XCTAssertTrue(waitUntilLeft(), "Menu on « Who's Watching? » did not go to the Home Screen")
    }

    /// From Settings: no Cancel button (Menu is the way back), the focus on
    /// the profile in use, Menu back to Settings as it was — the same row
    /// focused; in Manage mode, a first Menu leaves it, a second closes.
    func testThePickerFromSettingsClosesWithMenu() throws {
        launch(["-PTDebugProfiles", "Alex"])
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 20), "« Who's Watching? » never showed")
        pause(1.5)
        remote.press(.select)
        XCTAssertTrue(element("Home.Hero").waitForExistence(timeout: 30), "Me's Home never showed")

        try openSettingsRow("Settings.Row.switchProfile")
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 10), "the picker from Settings never showed")
        pause(1.5)
        snap("10-picker-from-settings")
        XCTAssertFalse(element("Profiles.Cancel").exists, "a Cancel button beside Manage Profiles")
        XCTAssertEqual(focusedIdentifier, "Profiles.Profile.Me", "the focus is not on the profile in use")
        XCTAssertEqual(element("Profiles.Profile.Me").value as? String, "Current profile", "VoiceOver does not say which profile is in use")
        remote.press(.menu)
        XCTAssertTrue(element("Profiles.Title").waitForNonExistence(timeout: 10), "Menu did not close the picker")
        pause(1)
        XCTAssertEqual(focusedIdentifier, "Settings.Row.switchProfile", "Settings did not come back as it was")

        // Manage mode: Menu leaves it, then closes.
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 10), "the picker did not show again")
        pause(1.5)
        remote.press(.down)
        pause(0.8)
        remote.press(.select)
        pause(1)
        XCTAssertEqual(element("Profiles.Title").label, "Manage Profiles", "Manage mode did not start")
        XCTAssertEqual(element("Profiles.Profile.Alex").label, "Edit Alex", "VoiceOver does not say a press edits")
        remote.press(.menu)
        pause(1)
        XCTAssertEqual(element("Profiles.Title").label, "Who’s Watching?", "Menu did not leave Manage mode")
        remote.press(.menu)
        XCTAssertTrue(element("Profiles.Title").waitForNonExistence(timeout: 10), "a second Menu did not close the picker")
    }

    /// The editor of a new profile starts on its name; Menu cancels it.
    func testTheEditorStartsOnTheName() throws {
        launch(["-PTDebugProfiles", "Alex"])
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 20), "« Who's Watching? » never showed")
        pause(1.5)
        for _ in 0..<4 where focusedIdentifier != "Profiles.Add" {
            remote.press(.right)
            pause(0.8)
        }
        XCTAssertEqual(focusedIdentifier, "Profiles.Add", "Add Profile never got the focus")
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Editor.Name").waitForExistence(timeout: 10), "the editor never showed")
        pause(1.5)
        snap("11-editor-new")
        XCTAssertEqual(focusedIdentifier, "Profiles.Editor.Name", "the editor does not start on the name")
        // Down to the avatars, from the field; Up from the last column back to it.
        remote.press(.down)
        pause(0.8)
        for _ in 0..<6 { remote.press(.right); pause(0.4) }
        XCTAssertEqual(focusedIdentifier, "Profiles.Editor.Avatar.5", "the first row's last avatar is not reachable")
        remote.press(.up)
        pause(0.8)
        XCTAssertEqual(focusedIdentifier, "Profiles.Editor.Name", "Up from the last column did not reach the name")
        remote.press(.menu)
        XCTAssertTrue(element("Profiles.Editor.Name").waitForNonExistence(timeout: 10), "Menu did not close the editor")
        XCTAssertTrue(element("Profiles.Title").exists, "Menu left the picker too")
    }

    /// A link that comes while « Who's Watching? » asks (the Top Shelf) is
    /// opened once a profile is picked.
    func testALinkDuringTheLaunchQuestionOpensAfterThePick() throws {
        launch(["-PTDebugProfiles", "Alex", "-PTDebugActivationURL", "popcorntime://show/tt0903747"])
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 20), "« Who's Watching? » never showed")
        pause(1.5)
        remote.press(.home)
        XCTAssertTrue(waitUntilLeft(), "the TV button did not go to the Home Screen")
        pause(2)
        app.activate()
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 10), "the question is gone")
        pause(2)
        XCTAssertFalse(element("Detail.Title").exists, "the page opened before a profile was picked")
        remote.press(.select)
        XCTAssertTrue(element("Detail.Title").waitForExistence(timeout: 60), "the link was not opened after the pick")
    }

    /// « Your Languages » (forced with `-PTDebugLanguagesScreen YES`): the
    /// focus starts on Continue; Anime's audio set to Japanese in the glass
    /// picker; Continue; Settings › Profiles › « Languages by Type » says
    /// Anime and its editor shows Japanese; Menu closes it.
    func testYourLanguagesScreenAndItsSettingsRow() throws {
        launch(["-PTDebugLanguagesScreen", "YES"])
        XCTAssertTrue(element("Languages.Screen").waitForExistence(timeout: 30), "« Your Languages » never showed")
        XCTAssertEqual(element("Languages.Screen").label, "Your Languages")
        XCTAssertTrue(element("Languages.Later").exists, "no Later button")
        pause(1.5)
        snap("12-your-languages")
        XCTAssertEqual(focusedIdentifier, "Languages.Continue", "the focus does not start on Continue")

        // Anime › Audio › Japanese.
        moveFocus(to: "Languages.Row.anime.audio")
        remote.press(.select)
        XCTAssertTrue(element("Settings.Picker").waitForExistence(timeout: 10), "the audio picker never showed")
        pause(1)
        for _ in 0..<80 where focusedElement.label != "Japanese" {
            remote.press(.down)
            pause(0.25)
        }
        XCTAssertEqual(focusedElement.label, "Japanese", "Japanese is not offered")
        snap("13-anime-audio-picker")
        remote.press(.select)
        XCTAssertTrue(element("Settings.Picker").waitForNonExistence(timeout: 10), "the picker stayed")
        pause(1)
        XCTAssertTrue(languageValue("Languages.Row.anime.audio").contains("Japanese"), "Anime's audio")
        XCTAssertEqual(element("Languages.Row.anime.audio").label, "Anime, Audio", "VoiceOver does not name the type")
        XCTAssertEqual(focusedIdentifier, "Languages.Row.anime.audio", "the focus did not come back to the row")

        // Continue: the screen goes, the Home is there.
        moveFocus(to: "Languages.Continue")
        remote.press(.select)
        XCTAssertTrue(element("Languages.Screen").waitForNonExistence(timeout: 10), "Continue did not close the screen")

        // Settings › Profiles › Languages by Type.
        try openSettingsRow("Settings.Row.contentLanguages")
        let row = element("Settings.Row.contentLanguages")
        XCTAssertTrue(row.label.contains("Anime"), "the row does not say Anime: \(row.label)")
        snap("14-settings-row")
        remote.press(.select)
        XCTAssertTrue(element("Languages.Screen").waitForExistence(timeout: 10), "the editor never showed")
        XCTAssertEqual(element("Languages.Screen").label, "Languages by Type")
        XCTAssertFalse(element("Languages.Later").exists, "Later in the Settings editor")
        XCTAssertTrue(languageValue("Languages.Row.anime.audio").contains("Japanese"), "Anime's audio was not kept")
        XCTAssertTrue(languageValue("Languages.Row.movie.audio").hasPrefix("Automatic"), "Movies & Shows changed too")
        pause(1)
        snap("15-settings-editor")
        remote.press(.menu)
        XCTAssertTrue(element("Languages.Screen").waitForNonExistence(timeout: 10), "Menu did not close the editor")
        pause(1)
        XCTAssertEqual(focusedIdentifier, "Settings.Row.contentLanguages", "the focus left the row")
    }

    // MARK: - Helpers

    /// A « Your Languages » button's value (its label names the type and « Audio »).
    private func languageValue(_ identifier: String) -> String {
        return element(identifier).value as? String ?? ""
    }

    /// Moves the focus to an element by its place on screen.
    private func moveFocus(to identifier: String) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no \(identifier)")
        for _ in 0..<12 where focusedIdentifier != identifier {
            let focused = focusedElement
            guard focused.exists else { remote.press(.down); pause(0.6); continue }
            let (from, to) = (focused.frame, target.frame)
            if to.midY < from.minY {
                remote.press(.up)
            } else if to.midY > from.maxY {
                remote.press(.down)
            } else {
                remote.press(to.midX < from.midX ? .left : .right)
            }
            pause(0.6)
        }
        XCTAssertEqual(focusedIdentifier, identifier, "\(identifier) never got the focus")
    }

    /// From the Home: the tab bar, Settings, then the focus on a row of the
    /// right column (the Profiles section is its top).
    private func openSettingsRow(_ identifier: String) throws {
        pause(2)
        for _ in 0..<4 where !tabBarHasFocus {
            remote.press(.up)
            pause(0.8)
        }
        XCTAssertTrue(tabBarHasFocus, "the tab bar never got the focus: \(focusedIdentifier)")
        for _ in 0..<8 where selectedTab != "settings" {
            remote.press(.right)
            pause(1)
        }
        XCTAssertEqual(selectedTab, "settings", "Settings never got selected")
        XCTAssertTrue(element(identifier).waitForExistence(timeout: 10), "Settings has no \(identifier)")
        remote.press(.down)
        pause(1)
        for _ in 0..<10 where focusedIdentifier != identifier {
            let row = element(identifier)
            let focused = focusedElement
            if !focusedIsInRightColumn {
                remote.press(.right)
            } else {
                remote.press(focused.exists && focused.frame.minY > row.frame.minY ? .up : .down)
            }
            pause(0.8)
        }
        XCTAssertEqual(focusedIdentifier, identifier, "\(identifier) never got the focus")
    }

    /// From the Home: the tab bar, Settings, « Switch Profile », then `moves`
    /// to the right (to the left when negative) from the profile in use, and
    /// a press.
    private func switchProfile(to name: String, moves: Int) throws {
        pause(2)
        for _ in 0..<4 where !tabBarHasFocus {
            remote.press(.up)
            pause(0.8)
        }
        XCTAssertTrue(tabBarHasFocus, "the tab bar never got the focus: \(focusedIdentifier)")
        for _ in 0..<8 where selectedTab != "settings" {
            remote.press(.right)
            pause(1)
        }
        XCTAssertEqual(selectedTab, "settings", "Settings never got selected")
        let row = element("Settings.Row.switchProfile")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings has no « Switch Profile » row")
        remote.press(.down)
        pause(1)
        // The row is the right column's first: up from any other row of it.
        for _ in 0..<8 where focusedIdentifier != "Settings.Row.switchProfile" {
            remote.press(focusedIsInRightColumn ? .up : .right)
            pause(0.8)
        }
        XCTAssertEqual(focusedIdentifier, "Settings.Row.switchProfile", "« Switch Profile » never got the focus")
        snap("3-settings-\(name)")
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Title").waitForExistence(timeout: 10), "the picker from Settings never showed")
        pause(1.5)
        for _ in 0..<abs(moves) {
            remote.press(moves > 0 ? .right : .left)
            pause(0.8)
        }
        XCTAssertEqual(focusedIdentifier, "Profiles.Profile.\(name)", "the focus is not on \(name)")
        remote.press(.select)
        XCTAssertTrue(element("Profiles.Title").waitForNonExistence(timeout: 10), "the picker stayed")
    }

    private func waitUntilLeft(timeout: TimeInterval = 8) -> Bool {
        if app.wait(for: .runningBackground, timeout: timeout) { return true }
        return [.runningBackgroundSuspended, .notRunning].contains(app.state)
    }

    private var focusedIsInRightColumn: Bool {
        let focused = focusedElement
        return focused.exists && focused.frame.minX > app.windows.firstMatch.frame.midX
    }

    private func launch(_ arguments: [String]) {
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
            "-PTDebugHomeHero", "0",
            "-PTDebugSettingsRow", "switchProfile",
        ] + arguments
        app.launch()
        self.app = app
    }

    private static var fixtures: String {
        if let folder = ProcessInfo.processInfo.environment["PT_UITEST_HOME_FIXTURES"], !folder.isEmpty { return folder }
        return URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PopcornTimeTests/Fixtures/Home").path
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

    private var tabBarHasFocus: Bool {
        app.tabBars.descendants(matching: .any).matching(Self.focused).firstMatch.exists
    }

    private var selectedTab: String {
        let bar = app.tabBars.firstMatch
        guard bar.exists else { return "none" }
        let identifier = bar.identifier
        return identifier.hasPrefix("TabBar.") ? String(identifier.dropFirst("TabBar.".count)) : "none (\(identifier))"
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ step: String) {
        guard let folder = ProcessInfo.processInfo.environment["PT_UITEST_SHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("profiles-\(step).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
