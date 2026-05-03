

import SwiftUI
import PopcornKit

struct SettingsView: View {
    @AppStorage("autoSelectQuality") private var autoSelectQuality = "Highest"
    @AppStorage("streamOnCellular")  private var streamOnCellular  = false

    var body: some View {
        Form {
            Section("Lecture") {
                Picker("Qualité automatique", selection: $autoSelectQuality) {
                    Text("La plus haute").tag("Highest")
                    Text("La plus basse").tag("Lowest")
                    Text("Choisir à chaque fois").tag("")
                }
                .pickerStyle(.menu)

                Toggle("Streamer en données mobiles", isOn: $streamOnCellular)
            }

            Section("Sources") {
                LabeledContent("API Films", value: "movies-api.accel.li")
                LabeledContent("API Séries", value: "eztvx.to (+ miroirs)")
                LabeledContent("Métadonnées", value: "TVMaze + TMDB")
            }

            Section("À propos") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                Link(destination: URL(string: "https://github.com/PopcornTimeTV/PopcornTimeTV")!) {
                    Label("Code source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        let v = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = object(forInfoDictionaryKey: "CFBundleVersion")            as? String ?? "?"
        return "\(v) (\(b))"
    }
}

#Preview {
    NavigationStack { SettingsView().navigationTitle("Réglages") }
        .preferredColorScheme(.dark)
}
