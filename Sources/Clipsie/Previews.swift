import AppKit
import QuickLookThumbnailing

enum RichPreview {
    static func color(in text: String) -> NSColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count <= 40, !value.isEmpty else { return nil }
        if value.hasPrefix("#") { return hexColor(String(value.dropFirst())) }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let function = value[..<open].trimmingCharacters(in: .whitespaces)
        let arguments = value[value.index(after: open)..<value.index(before: value.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace }).map(String.init)
        guard arguments.count == 3 || arguments.count == 4 else { return nil }
        let alpha = arguments.count == 4 ? fraction(arguments[3], scale: 1) : 1
        switch function {
        case "rgb", "rgba":
            let channels = arguments.prefix(3).map { fraction($0, scale: 255) }
            guard let red = channels[0], let green = channels[1], let blue = channels[2], let alpha else { return nil }
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        case "hsl", "hsla":
            guard let hue = degrees(arguments[0]), let saturation = percent(arguments[1]),
                  let lightness = percent(arguments[2]), let alpha else { return nil }
            let (red, green, blue) = rgb(hue: hue, saturation: saturation, lightness: lightness)
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        default:
            return nil
        }
    }

    private static func hexColor(_ digits: String) -> NSColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let full = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        let bytes = stride(from: 0, to: full.count, by: 2).map { offset -> CGFloat in
            let start = full.index(full.startIndex, offsetBy: offset)
            return CGFloat(UInt8(full[start..<full.index(start, offsetBy: 2)], radix: 16) ?? 0) / 255
        }
        return NSColor(srgbRed: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? bytes[3] : 1)
    }

    private static func fraction(_ value: String, scale: CGFloat) -> CGFloat? {
        let result: CGFloat?
        if value.hasSuffix("%") {
            result = Double(value.dropLast()).map { CGFloat($0) / 100 }
        } else {
            result = Double(value).map { CGFloat($0) / scale }
        }
        guard let result, (0...1).contains(result) else { return nil }
        return result
    }

    private static func percent(_ value: String) -> CGFloat? {
        value.hasSuffix("%") ? fraction(value, scale: 1) : nil
    }

    private static func degrees(_ value: String) -> CGFloat? {
        let number = value.hasSuffix("deg") ? String(value.dropLast(3)) : value
        return Double(number).map { CGFloat($0.truncatingRemainder(dividingBy: 360) + ($0 < 0 ? 360 : 0)) }
    }

    private static func rgb(hue: CGFloat, saturation: CGFloat, lightness: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let h = hue / 60
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch h {
        case ..<1: (r, g, b) = (chroma, x, 0)
        case ..<2: (r, g, b) = (x, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, x)
        case ..<4: (r, g, b) = (0, x, chroma)
        case ..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let m = lightness - chroma / 2
        return (r + m, g + m, b + m)
    }

    static func swatch(_ color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: size * 0.2, yRadius: size * 0.2)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor.white.setFill()
            rect.fill()
            let cell = max(2, size / 6)
            NSColor(white: 0.8, alpha: 1).setFill()
            for row in 0..<Int(ceil(size / cell)) {
                for column in 0..<Int(ceil(size / cell)) where (row + column) % 2 == 0 {
                    NSRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill()
                }
            }
            color.setFill()
            rect.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
    }

    static func colorDescription(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "" }
        let r = srgb.redComponent, g = srgb.greenComponent, b = srgb.blueComponent, a = srgb.alphaComponent
        func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        var hex = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        if a < 1 { hex += String(format: "%02X", byte(a)) }
        let alpha = a < 1 ? String(format: " / %.2g", Double(a)) : ""
        let maxValue = max(r, g, b), minValue = min(r, g, b)
        let lightness = (maxValue + minValue) / 2
        let delta = maxValue - minValue
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        var hue: CGFloat = 0
        if delta > 0 {
            switch maxValue {
            case r: hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = 60 * ((b - r) / delta + 2)
            default: hue = 60 * ((r - g) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        return [
            hex,
            "rgb(\(byte(r)) \(byte(g)) \(byte(b))\(alpha))",
            "hsl(\(Int(hue.rounded())) \(Int((saturation * 100).rounded()))% \(Int((lightness * 100).rounded()))%\(alpha))",
        ].joined(separator: "\n")
    }

    private static let maxHighlightedLength = 500_000

    static func highlightedJSON(_ text: String, font: NSFont) -> NSAttributedString? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count <= maxHighlightedLength, trimmed.first == "{" || trimmed.first == "[",
              (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { return nil }
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        let units = Array(text.utf16)
        func color(_ start: Int, _ end: Int, _ color: NSColor) {
            result.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: end - start))
        }
        func ascii(_ character: Unicode.Scalar) -> UInt16 { UInt16(character.value) }
        let quote = ascii("\""), backslash = ascii("\\"), colon = ascii(":")
        let whitespace: Set<UInt16> = [ascii(" "), ascii("\t"), ascii("\n"), ascii("\r")]
        let digits = ascii("0")...ascii("9"), letters = ascii("a")...ascii("z")
        let numberParts = Set("0123456789+-.eE".unicodeScalars.map(ascii))
        var index = 0
        while index < units.count {
            let unit = units[index]
            let start = index
            if unit == quote {
                index += 1
                while index < units.count, units[index] != quote {
                    index += units[index] == backslash ? 2 : 1
                }
                index = min(index + 1, units.count)
                var next = index
                while next < units.count, whitespace.contains(units[next]) { next += 1 }
                color(start, index, next < units.count && units[next] == colon ? .systemPurple : .systemRed)
            } else if unit == ascii("-") || digits.contains(unit) {
                while index < units.count, numberParts.contains(units[index]) { index += 1 }
                color(start, index, .systemBlue)
            } else if unit == ascii("t") || unit == ascii("f") || unit == ascii("n") {
                while index < units.count, letters.contains(units[index]) { index += 1 }
                color(start, index, .systemPink)
            } else {
                index += 1
            }
        }
        return result
    }

    static func fileDetails(_ paths: [String], limit: Int = 50) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let sizes = ByteCountFormatter()
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        for path in paths.prefix(limit) {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let icon = exists ? NSWorkspace.shared.icon(forFile: path)
                : NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil) ?? NSImage()
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -8, width: 32, height: 32)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  " + url.lastPathComponent + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.textColor,
            ]))
            var details: [String] = []
            if exists {
                let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey,
                                                               .contentModificationDateKey])
                if let kind = values?.localizedTypeDescription { details.append(kind) }
                if !isDirectory.boolValue, let size = values?.fileSize { details.append(sizes.string(fromByteCount: Int64(size))) }
                if let modified = values?.contentModificationDate { details.append("modified \(dates.string(from: modified))") }
            } else {
                details.append("Missing: moved, renamed or deleted since it was copied")
            }
            result.append(NSAttributedString(string: details.joined(separator: " · ") + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: exists ? NSColor.secondaryLabelColor : NSColor.systemRed,
            ]))
            result.append(NSAttributedString(string: url.deletingLastPathComponent().path + "\n\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        if paths.count > limit {
            result.append(NSAttributedString(string: "… and \(paths.count - limit) more", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return result
    }

    static func thumbnail(for path: String, size: CGSize, completion: @escaping (NSImage?) -> Void) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size, scale: scale,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            DispatchQueue.main.async { completion(representation?.nsImage) }
        }
    }

    static func singleURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 4000, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

enum LinkTitles {
    private static var cache: [URL: String?] = [:]
    private static var loading: Set<URL> = []
    private static let maxBytes = 256 * 1024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    static func title(for url: URL, onLoad: @escaping () -> Void) -> String?? {
        if let cached = cache[url] { return .some(cached) }
        guard !loading.contains(url) else { return nil }
        loading.insert(url)
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        Task {
            var data = Data()
            if let (bytes, response) = try? await session.bytes(for: request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               http.mimeType?.contains("html") ?? true {
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count >= maxBytes { break }
                    }
                } catch {}
            }
            let title = parseTitle(data)
            await MainActor.run {
                loading.remove(url)
                cache[url] = .some(title)
                onLoad()
            }
        }
        return nil
    }

    static func parseTitle(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let patterns = [
            #"<meta[^>]+property=["']og:title["'][^>]+content=(["'])(.*?)\1"#,
            #"<meta[^>]+content=(["'])(.*?)\1[^>]+property=["']og:title["']"#,
            #"<title[^>]*>([^<]+)</title>"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: match.numberOfRanges - 1), in: html) else { continue }
            let title = decodeEntities(String(html[range])).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !title.isEmpty { return String(title.prefix(300)) }
        }
        return nil
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let hexFlag = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result),
                      let code = UInt32(result[digits], radix: result[hexFlag].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
