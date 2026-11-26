import Foundation
import AppKit
import SwiftUI
import PopcornKit

// MARK: - Go

/// Go: the sidebar's sections (⌘1, ⌘2…), Search (⌘F: its field gets the
/// keyboard), Back (⌘[) and Refresh (⌘R) — on the window in front, through
/// its `MacNavigator`: the focused scene's (`MacRootView` publishes it as
/// the scene's focused object), else the last window that was in front
/// (`MacFrontNavigator`).
struct MacGoCommands: Commands {
    @FocusedObject private var focused: MacNavigator?
    @ObservedObject private var front = MacFrontNavigator.shared

    private var navigator: MacNavigator? { focused ?? front.navigator }

    var body: some Commands {
        CommandMenu("Go") {
            Group {
                ForEach(MacSection.numbered) { section in
                    Button {
                        perform { $0.select(section) }
                    } label: {
                        section.title
                    }
                    .keyboardShortcut(section.shortcut.map { KeyboardShortcut($0, modifiers: .command) })
                }
                Button("Search") { perform { $0.focusSearch() } }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("Back") { perform { $0.goBack() } }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(navigator?.canGoBack != true)
                Button("Refresh") { perform { $0.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(navigator?.canRefresh != true)
            }
            .disabled(navigator == nil)
        }
    }

    /// Not under a sheet (the player, the quality picker, the release
    /// notes): leaving the page would close it — the player with it.
    private func perform(_ action: (MacNavigator) -> Void) {
        guard let navigator else { return }
        if MacNavigator.isASheetUp {
            NSSound.beep()
            return
        }
        action(navigator)
    }
}

// MARK: - Profiles

/// Popcorn Time › Switch Profile… (⇧⌘P), under Settings…: « Who's
/// Watching? » as a sheet on the window in front (`MacRootView`); with no
/// main window, one is opened for it. Not while a window asks the launch
/// question (it is already on screen), nor under a sheet — the player
/// among them: a switch makes the window again and would close it.
struct MacProfileCommands: Commands {
    @FocusedObject private var focused: MacNavigator?
    @ObservedObject private var front = MacFrontNavigator.shared
    @ObservedObject private var question = ProfileLaunchQuestion.shared

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button(profilesLocalized("Profiles.Switch") + "…") { switchProfile() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(question.isAsking)
        }
    }

    private func switchProfile() {
        if MacNavigator.isASheetUp {
            NSSound.beep()
            return
        }
        if let navigator = focused ?? front.navigator {
            navigator.showsProfilePicker = true
        } else {
            front.showProfilePickerInNewWindow()
        }
    }
}

// MARK: - Playback

/// A track (audio, subtitles) a player offers the Playback menu.
struct MacCommandTrack: Identifiable, Equatable {
    let id: String
    let name: String
    let isSelected: Bool
}

/// What the Playback menu shows of the player in front.
struct MacPlaybackCommandState: Equatable {
    var isPlaying = false
    var audioTracks: [MacCommandTrack] = []
    /// The first entry turns subtitles off.
    var subtitleTracks: [MacCommandTrack] = []
}

/// What the Playback menu asks of a player.
struct MacPlaybackCommandHandlers {
    var togglePlay: () -> Void
    /// Seconds forward (negative: back).
    var skip: (Double) -> Void
    var selectAudioTrack: (String) -> Void
    var selectSubtitleTrack: (String) -> Void
}

/// Connects the Playback menu to the player in use. A player registers
/// when it starts playing — the native one, then VLC when it takes the
/// stream over — reports what it plays (`update`), and leaves when it
/// stops; the menu acts on the last one that registered. Not a focused
/// value: the player is a sheet, and commands must reach it whichever of
/// its views has the keyboard.
@MainActor
final class MacPlaybackCommandCenter: ObservableObject {
    static let shared = MacPlaybackCommandCenter()

    /// The player in front's state; nil: nothing is playing (the menu is
    /// disabled).
    @Published private(set) var state: MacPlaybackCommandState?
    /// A player's window has the keyboard: only then does the menu claim
    /// the bare keys (Space, the arrows). Elsewhere they belong to whatever
    /// is typed in (the search field of another window).
    @Published private(set) var playerHasKeyboard = false

    private struct Registration {
        weak var owner: AnyObject?
        var handlers: MacPlaybackCommandHandlers
        var state = MacPlaybackCommandState()
    }

    private var registrations: [Registration] = []
    private var keyWindows = Set<ObjectIdentifier>()

    private init() {}

    private var current: Registration? {
        registrations.last { $0.owner != nil }
    }

    /// `owner` plays from now on (again: its handlers are replaced).
    func register(_ owner: AnyObject, handlers: MacPlaybackCommandHandlers) {
        registrations.removeAll { $0.owner == nil || $0.owner === owner }
        registrations.append(Registration(owner: owner, handlers: handlers))
        publish()
    }

    /// `owner` stopped, or handed its stream over.
    func unregister(_ owner: AnyObject) {
        registrations.removeAll { $0.owner == nil || $0.owner === owner }
        publish()
    }

    /// What `owner` plays now. Published only when it changed: the menu is
    /// not rebuilt at every tick of a player's timer.
    func update(_ owner: AnyObject, _ newState: MacPlaybackCommandState) {
        guard let index = registrations.firstIndex(where: { $0.owner === owner }),
              registrations[index].state != newState else { return }
        registrations[index].state = newState
        publish()
    }

    /// The window of the player sheet `session` became key, or no longer is.
    func setKeyboard(_ hasKeyboard: Bool, session: AnyObject) {
        if hasKeyboard {
            keyWindows.insert(ObjectIdentifier(session))
        } else {
            keyWindows.remove(ObjectIdentifier(session))
        }
        let value = !keyWindows.isEmpty
        if value != playerHasKeyboard { playerHasKeyboard = value }
    }

    private func publish() {
        let newState = current?.state
        if newState != state { state = newState }
    }

    // The menu's actions.

    func togglePlay() { current?.handlers.togglePlay() }
    func skip(by seconds: Double) { current?.handlers.skip(seconds) }
    func selectAudioTrack(_ id: String) { current?.handlers.selectAudioTrack(id) }
    func selectSubtitleTrack(_ id: String) { current?.handlers.selectSubtitleTrack(id) }
}

/// Playback: Play / Pause (Space), ±10 seconds (← →), and the audio and
/// subtitle tracks of what plays — the native player or VLC. Disabled
/// while nothing plays.
struct MacPlaybackCommands: Commands {
    /// Seconds one skip moves the playhead.
    static let skipSeconds: Double = 10

    @ObservedObject private var center = MacPlaybackCommandCenter.shared

    var body: some Commands {
        CommandMenu("Playback") {
            let state = center.state
            // Bare keys, as in every player — but only while a player's
            // window has the keyboard.
            let keys = state != nil && center.playerHasKeyboard
            Group {
                Button {
                    center.togglePlay()
                } label: {
                    state?.isPlaying == true ? Text("Pause") : Text("Play")
                }
                .keyboardShortcut(keys ? KeyboardShortcut(.space, modifiers: []) : nil)
                Button("Skip Forward 10 Seconds") { center.skip(by: Self.skipSeconds) }
                    .keyboardShortcut(keys ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
                Button("Skip Back 10 Seconds") { center.skip(by: -Self.skipSeconds) }
                    .keyboardShortcut(keys ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
                Divider()
                trackMenu("Audio", tracks: state?.audioTracks ?? []) { center.selectAudioTrack($0) }
                trackMenu("Subtitles", tracks: state?.subtitleTracks ?? []) { center.selectSubtitleTrack($0) }
            }
            .disabled(state == nil)
        }
    }

    /// A submenu of tracks, the one in use checked.
    private func trackMenu(_ title: LocalizedStringKey, tracks: [MacCommandTrack],
                           select: @escaping (String) -> Void) -> some View {
        Menu(title) {
            ForEach(tracks) { track in
                Toggle(isOn: Binding(get: { track.isSelected }, set: { isOn in if isOn { select(track.id) } })) {
                    Text(verbatim: track.name)
                }
            }
        }
        .disabled(tracks.isEmpty)
    }
}
