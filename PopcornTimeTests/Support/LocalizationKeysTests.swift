//
//  LocalizationKeysTests.swift
//  PopcornTimeTests
//
//  Every Localizable.strings the apps ship has the same keys: a key added to en / fr only
//  reads in English in the middle of a Spanish, Italian, Arabic or Portuguese screen (the
//  Mac's Go menu, Refresh and Search hint did, in 5.3's first stage).
//

import XCTest
import Foundation

final class LocalizationKeysTests: CheckedTestCase {

    func testEveryLanguageHasEveryKey() {
        let folder = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PopcornTime")
        let languages = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
            name.hasSuffix(".lproj") && FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name)/Localizable.strings").path)
        }.sorted()
        check(Set(languages).isSuperset(of: ["Base.lproj", "ar.lproj", "en.lproj", "es.lproj", "fr.lproj", "it.lproj", "pt-BR.lproj"]),
              "every strings file is found", "\(languages)")
        func keys(_ language: String) -> Set<String> {
            let strings = NSDictionary(contentsOf: folder.appendingPathComponent("\(language)/Localizable.strings")) as? [String: String]
            check(strings != nil, "\(language): the file reads")
            return Set((strings ?? [:]).keys)
        }
        let english = keys("en.lproj")
        check(english.count > 300, "the English keys", "\(english.count)")
        for language in languages where language != "en.lproj" {
            let other = keys(language)
            let missing = english.subtracting(other).sorted()
            let extra = other.subtracting(english).sorted()
            check(missing.isEmpty, "\(language): every English key is translated", "\(missing.prefix(10))")
            check(extra.isEmpty, "\(language): no key English lacks", "\(extra.prefix(10))")
        }
    }
}
