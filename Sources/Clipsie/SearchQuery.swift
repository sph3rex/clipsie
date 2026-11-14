import AppKit

struct SearchQuery {
    enum ContentType: String {
        case text, rich, image, file, link, color, other
    }

    enum Flag: String {
        case pinned, tagged, titled
    }

    private(set) var terms: [String] = []
    private(set) var apps: [String] = []
    private(set) var types: [ContentType] = []
    private(set) var flags: [Flag] = []
    private(set) var tags: [String] = []
    private(set) var after: Date?
    private(set) var before: Date?

    var hasFilters: Bool {
        !apps.isEmpty || !types.isEmpty || !flags.isEmpty || !tags.isEmpty || after != nil || before != nil
    }

    init(_ query: String, now: Date = Date(), calendar: Calendar = .current) {
        for word in query.split(whereSeparator: \.isWhitespace).map(String.init) {
            if !apply(word, now: now, calendar: calendar) { terms.append(word.lowercased()) }
        }
    }

    private mutating func apply(_ word: String, now: Date, calendar: Calendar) -> Bool {
        guard let colon = word.firstIndex(of: ":") else { return false }
        let key = word[..<colon].lowercased()
        let value = word[word.index(after: colon)...].lowercased()
        guard !value.isEmpty else { return false }
        switch key {
        case "tag":
            tags.append(value)
        case "app":
            apps.append(value)
        case "type":
            guard let type = ContentType(rawValue: Self.typeAliases[value] ?? value) else { return false }
            types.append(type)
        case "is":
            guard let flag = Flag(rawValue: Self.flagAliases[value] ?? value) else { return false }
            flags.append(flag)
        case "date":
            guard let range = Self.dayRange(value, now: now, calendar: calendar) else { return false }
            after = max(after ?? range.start, range.start)
            before = min(before ?? range.end, range.end)
        case "after":
            guard let day = Self.day(value, calendar) else { return false }
            after = max(after ?? day, day)
        case "before":
            guard let day = Self.day(value, calendar) else { return false }
            before = min(before ?? day, day)
        default:
            return false
        }
        return true
    }

    private static let typeAliases = [
        "texts": "text", "plain": "text", "formatted": "rich", "rtf": "rich", "html": "rich",
        "images": "image", "img": "image", "picture": "image", "files": "file",
        "links": "link", "url": "link", "urls": "link", "colors": "color", "colour": "color", "colours": "color",
    ]

    private static let flagAliases = [
        "pin": "pinned", "tag": "tagged", "tags": "tagged", "title": "titled",
    ]

    private static func dayRange(_ value: String, now: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let firstDay: Date?
        var days = 1
        switch value {
        case "today":
            firstDay = now
        case "yesterday":
            firstDay = calendar.date(byAdding: .day, value: -1, to: now)
        case "week":
            firstDay = calendar.date(byAdding: .day, value: -6, to: now)
            days = 7
        case "month":
            firstDay = calendar.date(byAdding: .day, value: -29, to: now)
            days = 30
        default:
            firstDay = Self.day(value, calendar)
        }
        guard let firstDay else { return nil }
        let start = calendar.startOfDay(for: firstDay)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        return (start, end)
    }

    private static func day(_ value: String, _ calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2] else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }

    var filterSummary: String {
        var parts = tags.map { "tag: \($0)" } + apps.map { "app: \($0)" }
        parts += types.map { type in
            switch type {
            case .text: return L("Text")
            case .rich: return L("Formatted text")
            case .image: return L("Images")
            case .file: return L("Files")
            case .link: return L("Links")
            case .color: return L("Colors")
            case .other: return L("Other")
            }
        }
        parts += flags.map { flag in
            switch flag {
            case .pinned: return L("Pinned")
            case .tagged: return L("Tagged")
            case .titled: return L("Titled")
            }
        }
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .none
        let lastDay = before.map { $0.addingTimeInterval(-1) }
        switch (after, lastDay) {
        case let (after?, last?) where Calendar.current.isDate(after, inSameDayAs: last):
            parts.append(dates.string(from: after))
        case let (after?, last?):
            parts.append(after > last ? L("No dates") : "\(dates.string(from: after)) – \(dates.string(from: last))")
        case let (after?, nil):
            parts.append(L("from %@", dates.string(from: after)))
        case let (nil, last?):
            parts.append(L("until %@", dates.string(from: last)))
        case (nil, nil):
            break
        }
        return parts.joined(separator: " · ")
    }

    static func app(_ bundleID: String, matches value: String) -> Bool {
        bundleID.lowercased().contains(value) || appName(bundleID)?.lowercased().contains(value) == true
    }

    private static let appNamesLock = NSLock()
    private static var appNames: [String: String?] = [:]

    static func appName(_ bundleID: String) -> String? {
        appNamesLock.lock()
        defer { appNamesLock.unlock() }
        if let cached = appNames[bundleID] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { $0.deletingPathExtension().lastPathComponent }
        appNames[bundleID] = .some(name)
        return name
    }
}
