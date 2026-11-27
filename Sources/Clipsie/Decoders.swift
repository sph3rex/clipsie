import Foundation

enum Decoders {
    struct Section: Equatable {
        let title: String
        let body: String
    }

    static func sections(for raw: String, now: Date = Date(), timeZone: TimeZone = .current) -> [Section] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000, !text.contains(where: \.isWhitespace) else { return [] }
        let section = jwt(text, now: now) ?? timestamp(text, timeZone: timeZone) ?? urlParameters(text) ?? base64(text)
        return section.map { [$0] } ?? []
    }

    static func jwt(_ text: String, now: Date) -> Section? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard text.hasPrefix("eyJ"), parts.count == 3,
              let header = object(base64URL(parts[0])), let payload = object(base64URL(parts[1])),
              let headerText = pretty(header), let payloadText = pretty(payload) else { return nil }
        var title = L("JWT")
        if let expiry = (payload["exp"] as? NSNumber)?.doubleValue {
            let date = Date(timeIntervalSince1970: expiry)
            let relative = relativeFormatter.localizedString(for: date, relativeTo: now)
            title += " · " + (date < now ? L("expired %@", relative) : L("expires %@", relative))
        }
        return Section(title: title, body: headerText + "\n" + payloadText)
    }

    static func timestamp(_ text: String, timeZone: TimeZone) -> Section? {
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Double(text) else { return nil }
        let milliseconds = text.count == 12 || text.count == 13
        guard milliseconds || text.count == 9 || text.count == 10 else { return nil }
        let seconds = milliseconds ? value / 1000 : value
        guard (978_307_200...4_102_444_800).contains(seconds) else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        func format(_ zone: TimeZone) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = zone
            formatter.formatOptions = milliseconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            return formatter.string(from: date)
        }
        return Section(title: L("Unix timestamp"), body: format(timeZone) + "\n" + format(TimeZone(identifier: "UTC")!))
    }

    static func urlParameters(_ text: String) -> Section? {
        guard let components = URLComponents(string: text), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let items = components.queryItems, !items.isEmpty else { return nil }
        return Section(title: L("URL parameters"), body: items.map { "\($0.name) = \($0.value ?? "")" }.joined(separator: "\n"))
    }

    static func base64(_ text: String) -> Section? {
        guard text.count >= 12, text.count % 4 == 0,
              text.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil,
              text.contains(where: { $0.isNumber || "+/=".contains($0) }),
              let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty, decoded.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || "\n\r\t".unicodeScalars.contains($0) })
        else { return nil }
        return Section(title: L("Base64, decoded"), body: decoded)
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()

    private static func base64URL(_ part: Substring) -> Data? {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    private static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func pretty(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

enum LineDiff {
    enum Kind: Equatable {
        case same, removed, added
    }

    struct Line: Equatable {
        let kind: Kind
        let text: String
    }

    static func lines(from old: String, to new: String) -> [Line] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Line] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                result.append(Line(kind: .removed, text: a[i]))
                i += 1
            } else if j < b.count, inserted.contains(j) {
                result.append(Line(kind: .added, text: b[j]))
                j += 1
            } else {
                result.append(Line(kind: .same, text: a[i]))
                i += 1
                j += 1
            }
        }
        return result
    }
}
