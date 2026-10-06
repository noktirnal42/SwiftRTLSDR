// SPDX-License-Identifier: GPL-2.0-or-later
//
// Calendar arithmetic for the radiosonde decoders. Written for this package.
import Foundation

/// GPS time (weeks and seconds from 1980-01-06, leap seconds not applied) and civil dates.
enum GPSTime {
    /// Days from 1980-01-06 to a civil date (proleptic Gregorian).
    static func daysSince1980(year: Int, month: Int, day: Int) -> Int {
        // Civil date to days since 1970-01-01, then to 1980-01-06 (3657 days later).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = (month + 9) % 12
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468 - 3657
    }

    /// The civil date `days` after 1980-01-06.
    static func date(daysSince1980 days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 3657 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
