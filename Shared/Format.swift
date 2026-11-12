import Foundation

/// Форматирование времени и дат по-русски. Логика длительностей та же, что на сайте.
enum Fmt {
    static let ru = Locale(identifier: "ru_RU")
    static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    static func formatter(_ format: String, tz: TimeZone) -> DateFormatter {
        let key = format + "|" + tz.identifier
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = ru
        formatter.timeZone = tz
        formatter.dateFormat = format
        cache[key] = formatter
        return formatter
    }

    static func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    /// 3 мин 44 с, 1 ч 56 мин, 2 д 4 ч — как timeFormat на сайте.
    static func duration(_ seconds: Double, detailed: Bool = false) -> String {
        let n = seconds.isFinite ? max(0, Int(seconds)) : 0
        let days = n / 86_400
        let hours = (n / 3_600) % 24
        let minutes = (n / 60) % 60
        let secs = n % 60
        if days > 0 { return "\(days) д \(hours) ч" }
        if hours > 0 { return "\(hours) ч \(two(minutes)) мин" + (detailed ? " \(two(secs)) с" : "") }
        if n < 60 { return "\(secs) с" }
        if detailed { return "\(minutes) мин \(two(secs)) с" }
        return "\(n / 60) мин"
    }

    static func compactMinutes(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) ч \(two(m % 60))" : "\(m) мин"
    }

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = ru
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    static func percent(_ value: Double) -> String {
        let clamped = min(100, max(0, value.isFinite ? value : 0))
        lock.lock()
        defer { lock.unlock() }
        return (percentFormatter.string(from: NSNumber(value: clamped)) ?? "\(Int(clamped))") + "%"
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let a = abs(n) % 100
        let b = a % 10
        if a > 10 && a < 20 { return many }
        if b > 1 && b < 5 { return few }
        if b == 1 { return one }
        return many
    }

    static func time(_ timestamp: Double, tz: TimeZone, seconds: Bool = false) -> String {
        formatter(seconds ? "HH:mm:ss" : "HH:mm", tz: tz).string(from: Date(timeIntervalSince1970: timestamp))
    }

    // MARK: Дни в формате YYYY-MM-DD

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    private static func parts(_ iso: String) -> (Int, Int, Int)? {
        let values = iso.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return (values[0], values[1], values[2])
    }

    private static func iso(_ components: DateComponents) -> String {
        String(format: "%04ld-%02ld-%02ld", components.year ?? 2000, components.month ?? 1, components.day ?? 1)
    }

    static func utcNoon(_ day: String) -> Date? {
        guard let p = parts(day) else { return nil }
        return utcCalendar.date(from: DateComponents(year: p.0, month: p.1, day: p.2, hour: 12))
    }

    static func shiftDay(_ day: String, _ offset: Int) -> String {
        guard let date = utcNoon(day), let shifted = utcCalendar.date(byAdding: .day, value: offset, to: date) else { return day }
        return iso(utcCalendar.dateComponents([.year, .month, .day], from: shifted))
    }

    static func dayText(_ day: String, _ format: String) -> String {
        guard let date = utcNoon(day) else { return day }
        return formatter(format, tz: utc).string(from: date)
    }

    static func isoDay(_ timestamp: Double, tz: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return iso(calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: timestamp)))
    }

    static func hourMinute(_ timestamp: Double, tz: TimeZone) -> (hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let components = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: timestamp))
        return (components.hour ?? 0, components.minute ?? 0)
    }

    /// Полдень выбранного дня в календаре телефона — для DatePicker.
    static func localDate(_ day: String) -> Date {
        guard let p = parts(day) else { return Date() }
        return Calendar.current.date(from: DateComponents(year: p.0, month: p.1, day: p.2, hour: 12)) ?? Date()
    }

    static func isoLocal(_ date: Date) -> String {
        iso(Calendar.current.dateComponents([.year, .month, .day], from: date))
    }

    static func cap(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    static func relative(_ day: String, today: String) -> String? {
        if day == today { return "Сегодня" }
        if day == shiftDay(today, -1) { return "Вчера" }
        return nil
    }

    /// «Сегодня», «Вчера», «Пн, 9 нояб.»
    static func shortDay(_ day: String, today: String) -> String {
        relative(day, today: today) ?? cap(dayText(day, "EE, d MMM"))
    }
}

enum Labels {
    static func state(_ state: String) -> String {
        switch state {
        case "online": return "В сети"
        case "offline": return "Офлайн"
        default: return "Нет данных"
        }
    }
}
