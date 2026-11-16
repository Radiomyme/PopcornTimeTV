//
//  ResumeStringsTests.swift
//  PopcornTimeTests
//
//  The texts of the native resume of a film that is still downloading, in the seven tables
//  the apps ship: the question's message when « Resume at … » plays natively
//  (Remux.Resume.Message — which no longer talks about VLC), its message when this file
//  resumes through VLC (Remux.Resume.Message.VLC — which does), and « Resuming at 1:40:00… »
//  under the spinner (Player.Resuming.At, one %@ everywhere).
//

import XCTest
import Foundation

final class ResumeStringsTests: CheckedTestCase {

    private static let tables = ["Base", "en", "fr", "es", "it", "pt-BR", "ar"]

    private func strings(_ table: String) -> [String: String]? {
        let folder = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PopcornTime")
        return NSDictionary(contentsOf: folder.appendingPathComponent("\(table).lproj/Localizable.strings")) as? [String: String]
    }

    private func placeholders(_ text: String) -> Int { text.components(separatedBy: "%@").count - 1 }

    func testTheThreeKeysAreInTheSevenTables() {
        var resuming: [String: String] = [:]
        var native: [String: String] = [:]
        var vlc: [String: String] = [:]
        for table in Self.tables {
            guard let strings = strings(table) else {
                check(false, "\(table): the table reads")
                continue
            }
            for (key, expected) in [("Remux.Resume.Message", 0), ("Remux.Resume.Message.VLC", 0), ("Player.Resuming.At", 1)] {
                let value = strings[key] ?? ""
                check(!value.isEmpty, "\(table): \(key) is there")
                eq(placeholders(value), expected, "\(table): \(key) has \(expected) %@")
                check(!value.contains("%d") && !value.contains("%1$") && !value.contains("%s"), "\(table): \(key) has no other format", value)
            }
            native[table] = strings["Remux.Resume.Message"]
            vlc[table] = strings["Remux.Resume.Message.VLC"]
            resuming[table] = strings["Player.Resuming.At"]
            // The button the label answers to, and the question's other texts, are still there.
            eq(placeholders(strings["Remux.Resume.At"] ?? ""), 1, "\(table): the button keeps its %@")
            check(!(strings["Remux.Resume.Title"] ?? "").isEmpty && !(strings["Remux.Resume.FromStart"] ?? "").isEmpty,
                  "\(table): the question's title and its other button")
        }
        for table in Self.tables {
            // A native resume keeps the best quality and no longer goes through VLC; the other
            // message says plainly that this file resumes through VLC.
            let message = native[table] ?? ""
            check(!message.contains("VLC"), "\(table): the native message does not talk about VLC", message)
            check(message.contains("HDR") && message.contains("Dolby Atmos"), "\(table): it names what is kept", message)
            let other = vlc[table] ?? ""
            check(other.contains("VLC"), "\(table): the VLC message names VLC", other)
            check(other.contains("HDR") && other.contains("Dolby Atmos"), "\(table): and what « from the beginning » keeps", other)
            check(message != other, "\(table): two different messages")
            // « Resuming at %@… »: the position, then an ellipsis (one character, as the
            // tables write it everywhere).
            let label = resuming[table] ?? ""
            check(label.hasSuffix("%@…"), "\(table): the position ends the label, before the ellipsis", label)
            check(label.count > 4, "\(table): with words before it", label)
        }
        eq(native["Base"], native["en"], "Base and en say the same (native)")
        eq(vlc["Base"], vlc["en"], "Base and en say the same (VLC)")
        eq(resuming["Base"], resuming["en"], "Base and en say the same (label)")
        eq(resuming["en"], "Resuming at %@…", "the English label")
        eq(resuming["fr"], "Reprise à %@…", "the French label")
        eq(native["fr"], "Ce fichier est encore en téléchargement. La lecture reprend à cet endroit en qualité native (HDR, Dolby Atmos).",
           "the French message")
        // Translated: no table but Base repeats the English text.
        for table in Self.tables where table != "Base" && table != "en" {
            check(native[table] != native["en"] && vlc[table] != vlc["en"] && resuming[table] != resuming["en"],
                  "\(table): translated")
        }
    }

    func testTheCodeAsksForThoseKeysWithTheEnglishTextAsDefault() {
        // In the test bundle no table is loaded: NSLocalizedString gives the code's own default
        // value, which must be the Base table's.
        guard let base = strings("Base") else { return check(false, "Base reads") }
        eq(ResumePolicy.resumeQuestionMessage(for: .native), base["Remux.Resume.Message"], "the native message's default")
        eq(ResumePolicy.resumeQuestionMessage(for: .vlc(reason: "no keyframe index")), base["Remux.Resume.Message.VLC"],
           "the VLC message's default — the reason is for the logs, not for the user")
        eq(ResumePolicy.resumingText(position: "1:40:00"), "Resuming at 1:40:00…", "the label with its position")
        eq(ResumePolicy.resumingText(position: "70 %"), "Resuming at 70 %…", "a percentage while the length is unknown: no format mishap")
        eq(ResumePolicy.resumingText(position: ResumePolicy.resumeLabel(fraction: 0.8, durationSeconds: 7500)), "Resuming at 1:40:00…",
           "the saved position of a film as the label shows it")
    }
}
