// HomeSettingsViews.swift — the two lists behind the Home's settings (iOS
// and macOS): the content languages and the shelves shown. Plain lists on
// `HomeSettingsModel`; each platform's settings screen has the rows that
// open them. A change is stored at once (PopcornKit's `HomeSettings`) and
// the page is rebuilt from what it already has: no request.
import Foundation
import SwiftUI
import PopcornKit

/// The original languages the Home keeps.
struct HomeLanguagesSettingsView: View {
    let state: HomeState

    @State private var everyLanguage = false
    @State private var languages: [HomeSettingsModel.Language] = []

    private var model: HomeSettingsModel { HomeSettingsModel(settings: HomeSettings()) }

    var body: some View {
        Form {
            Section {
                Toggle("Home.Settings.AllLanguages", isOn: Binding(get: { everyLanguage }, set: { on in
                    model.setShowsEveryLanguage(on)
                    changed()
                }))
                .accessibilityIdentifier("Home.Settings.AllLanguages")
            } footer: {
                Text("Home.Settings.Languages.Footer")
            }
            if !everyLanguage {
                Section {
                    ForEach(languages) { language in
                        Button {
                            model.toggleLanguage(language.id)
                            changed()
                        } label: {
                            HStack {
                                Text(verbatim: language.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if language.isOn {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(language.isOn ? .isSelected : [])
                        .accessibilityIdentifier("Home.Settings.Language.\(language.id)")
                    }
                }
            }
        }
        .navigationTitle("Home.Settings.Languages")
        .onAppear(perform: reload)
    }

    private func reload() {
        everyLanguage = model.showsEveryLanguage
        languages = model.languages
    }

    private func changed() {
        withAnimation(.easeInOut(duration: 0.2)) { reload() }
        state.refreshLocal()
    }
}

/// The shelves of the Home, each with its switch.
struct HomeShelvesSettingsView: View {
    let state: HomeState

    @State private var shelves: [HomeSettingsModel.Shelf] = []

    private var model: HomeSettingsModel { HomeSettingsModel(settings: HomeSettings()) }

    var body: some View {
        Form {
            Section {
                ForEach(shelves) { shelf in
                    Toggle(isOn: Binding(get: { shelf.isShown }, set: { shown in
                        model.setShelf(shelf.id, shown: shown)
                        reload()
                        state.refreshLocal()
                    })) {
                        Text(verbatim: shelf.title)
                    }
                    .accessibilityIdentifier("Home.Settings.Shelf.\(shelf.id)")
                }
            } footer: {
                Text("Home.Settings.Shelves.Footer")
            }
        }
        .navigationTitle("Home.Settings.Shelves")
        .onAppear(perform: reload)
    }

    private func reload() {
        shelves = model.shelves(current: state.shelves, listed: shelves)
    }
}
