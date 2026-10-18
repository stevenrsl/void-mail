import Foundation

/// Dates as one would say them, as in Void Notes: « 15:41 » today, « hier », the day of the week
/// within the week, then « 1 oct. », the year only when it isn't this one.
enum MailDate {
    static func listLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "hier" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days > 0, days < 7 {
            return weekday.string(from: date)
        }
        return (calendar.isDate(date, equalTo: now, toGranularity: .year) ? dayMonth : dayMonthYear).string(from: date)
    }

    /// « aujourd'hui à 15:41 », « hier à 9:02 », « le 1 oct. à 18:20 ».
    static func sentence(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let at = "à " + time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd'hui \(at)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "hier \(at)" }
        let day = (calendar.isDate(date, equalTo: now, toGranularity: .year) ? dayMonth : dayMonthYear).string(from: date)
        return "le \(day) \(at)"
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let time = formatter("Hm")
    private static let weekday = formatter("EEEE")
    private static let dayMonth = formatter("dMMM")
    private static let dayMonthYear = formatter("dMMMy")
}
