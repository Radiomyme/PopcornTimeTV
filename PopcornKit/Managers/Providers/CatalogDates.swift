import Foundation

/// The dates of the sources (Cinemeta, TVMaze): the ISO 8601 forms they use,
/// and day and year arithmetic in UTC. One place for the catalogs, the Home
/// feed and the library (each had its own reader; this is the Home feed's
/// parser, which needs no formatter, under the catalogs' name).
enum CatalogDates {

    /// "2026-07-31T00:00:00.000Z" (Cinemeta, with or without milliseconds),
    /// "2026-11-13T12:00:00+00:00" (TVMaze's airstamp), "2026-10-30" (a day:
    /// midnight UTC). nil for anything else.
    static func date(from text: String?) -> Date? {
        guard let text = text, text.utf8.count >= 10 else { return nil }
        let bytes = Array(text.utf8)
        func number(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[from..<(from + count)] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard let year = number(0, 4), bytes[4] == 0x2D, let month = number(5, 2), bytes[7] == 0x2D,
              let day = number(8, 2), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var seconds = Double(days(year: year, month: month, day: day)) * 86_400
        guard bytes.count > 10 else { return Date(timeIntervalSince1970: seconds) }
        guard bytes[10] == 0x54 || bytes[10] == 0x20, let hour = number(11, 2), bytes.count > 13, bytes[13] == 0x3A,
              let minute = number(14, 2), hour < 24, minute < 60 else { return nil }
        seconds += Double(hour * 3600 + minute * 60)
        var index = 16
        if index < bytes.count, bytes[index] == 0x3A {
            guard let second = number(index + 1, 2), second <= 60 else { return nil }
            seconds += Double(second)
            index += 3
        }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        }
        // No zone, or "Z": UTC. "+01:00" / "-0500": the offset is taken off.
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
            let sign: Double = bytes[index] == 0x2B ? 1 : -1
            guard let offsetHour = number(index + 1, 2) else { return nil }
            let minuteStart = index + 3 < bytes.count && bytes[index + 3] == 0x3A ? index + 4 : index + 3
            let offsetMinute = number(minuteStart, 2) ?? 0
            seconds -= sign * Double(offsetHour * 3600 + offsetMinute * 60)
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date.
    private static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civil(_ date: Date) -> (year: Int, month: Int, day: Int) {
        let z = Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// "2026-11-14" (UTC).
    static func dayString(_ date: Date) -> String {
        let (year, month, day) = civil(date)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The calendar year of `date` (UTC).
    static func year(of date: Date) -> Int {
        return civil(date).year
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let lock = NSLock()

    /// "2026-07-31T00:00:00.000Z": what `date(from:)` reads back.
    static func isoString(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return iso.string(from: date)
    }
}
