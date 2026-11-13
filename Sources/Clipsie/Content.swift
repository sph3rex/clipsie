import AppKit
import CryptoKit
import ImageIO

struct Representation {
    let itemIndex: Int
    let type: String
    let data: Data
}

enum ItemKind: Int {
    case text = 0, richText, image, files, other
}

struct ItemRow {
    let id: Int64
    let kind: ItemKind
    let preview: String
    let sourceApp: String?
    let byteSize: Int
    let pinned: Bool
    let usedAt: Date
    let tags: [String]
    let thumbnail: Data?
    let title: String?

    var important: Bool {
        tags.contains { $0.caseInsensitiveCompare(Store.importantTag) == .orderedSame }
    }
}

struct Capture {
    let representations: [Representation]
    let sourceApp: String?
    let text: String?
    let kind: ItemKind
    let preview: String
    let searchText: String
    let byteSize: Int
    let hash: String
    let thumbnail: Data?

    init(representations: [Representation], sourceApp: String?) {
        let paths = Content.filePaths(representations)
        let plain = Content.plainText(representations)
        var kind = ItemKind.other
        var preview: String

        if !paths.isEmpty {
            kind = .files
            preview = "📁 " + Content.previewLine(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        } else if let plain, !plain.isEmpty {
            kind = Content.hasRichText(representations) ? .richText : .text
            preview = Content.previewLine(plain)
            if preview.isEmpty { preview = "⎵ whitespace (\(plain.count) chars)" }
        } else if let image = Content.imageData(representations) {
            kind = .image
            preview = "🖼 " + Content.imageDescription(image)
        } else {
            preview = "[" + (representations.first?.type ?? "empty") + "]"
        }

        let text = Content.text(representations)
        self.representations = representations
        self.sourceApp = sourceApp
        self.text = text
        self.kind = kind
        self.preview = preview
        self.searchText = String((text ?? "").prefix(Content.searchTextLimit)).lowercased()
        self.byteSize = representations.reduce(0) { $0 + $1.data.count }
        self.hash = Content.hash(representations)
        self.thumbnail = Content.imageData(representations).flatMap { Content.thumbnail($0) }
    }

    init(text: String, sourceApp: String?) {
        let rep = Representation(itemIndex: 0, type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
        self.init(representations: [rep], sourceApp: sourceApp)
    }
}

enum Content {
    static let utf8Type = "public.utf8-plain-text"
    static let rtfType = "public.rtf"
    static let fileURLType = "public.file-url"
    static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif"]
    static let richTypes: Set<String> = ["public.rtf", "public.html", "com.apple.flat-rtfd"]
    static let searchTextLimit = 100_000

    static func text(_ reps: [Representation]) -> String? {
        let paths = filePaths(reps)
        return paths.isEmpty ? plainText(reps) : paths.joined(separator: "\n")
    }

    static func plainText(_ reps: [Representation]) -> String? {
        var parts: [String] = []
        for index in Set(reps.map(\.itemIndex)).sorted() {
            let item = reps.filter { $0.itemIndex == index }
            if let data = item.first(where: { $0.type == utf8Type })?.data, let s = String(data: data, encoding: .utf8) {
                parts.append(s)
            } else if let data = item.first(where: { $0.type == rtfType })?.data,
                      let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
                parts.append(attributed.string)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func filePaths(_ reps: [Representation]) -> [String] {
        reps.compactMap { rep in
            guard rep.type == fileURLType,
                  let string = String(data: rep.data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL else { return nil }
            return url.path
        }
    }

    static func imageData(_ reps: [Representation]) -> Data? {
        for type in imageTypes {
            if let rep = reps.first(where: { $0.type == type }) { return rep.data }
        }
        return nil
    }

    static func hasRichText(_ reps: [Representation]) -> Bool {
        reps.contains { richTypes.contains($0.type) }
    }

    static func isFormattedText(_ reps: [Representation]) -> Bool {
        hasRichText(reps) && filePaths(reps).isEmpty && imageData(reps) == nil && plainText(reps) != nil
    }

    private static let typeNames: [String: String] = [
        "public.utf8-plain-text": "Plain text", "public.utf16-external-plain-text": "Plain text",
        "public.utf16-plain-text": "Plain text", "NSStringPboardType": "Plain text",
        "public.rtf": "RTF", "com.apple.flat-rtfd": "RTFD", "public.html": "HTML",
        "com.apple.webarchive": "Web archive", "public.url": "URL", "public.file-url": "File",
        "public.png": "PNG", "public.tiff": "TIFF", "public.jpeg": "JPEG", "public.heic": "HEIC",
        "com.compuserve.gif": "GIF", "com.adobe.pdf": "PDF", "public.svg-image": "SVG",
    ]
    private static let typeOrder = ["Plain text", "RTF", "RTFD", "HTML", "Web archive", "URL", "File",
                                    "PNG", "TIFF", "JPEG", "HEIC", "GIF", "SVG", "PDF"]

    static func typeSummary(_ reps: [Representation]) -> String {
        var known: [String] = []
        var other = Set<String>()
        for type in reps.map(\.type) {
            if let name = typeNames[type] {
                if !known.contains(name) { known.append(name) }
            } else {
                other.insert(type)
            }
        }
        known.sort { (typeOrder.firstIndex(of: $0) ?? .max) < (typeOrder.firstIndex(of: $1) ?? .max) }
        var summary = known.joined(separator: " · ")
        if !other.isEmpty {
            summary += (summary.isEmpty ? "" : "  ") + "+\(other.count) app-specific"
        }
        return summary
    }

    static func fenced(_ text: String, with character: Character) -> String {
        var longest = 0
        var run = 0
        for ch in text {
            run = ch == character ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: character, count: max(3, longest + 1))
        return fence + "\n" + (text.hasSuffix("\n") ? text : text + "\n") + fence
    }

    static func thumbnail(_ data: Data, maxPixels: Int = 88) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    static func imageDescription(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return "Image" }
        return "Image \(width)×\(height)"
    }

    static func previewLine(_ text: String, limit: Int = 200) -> String {
        var result = ""
        var count = 0
        var pendingSpace = false
        for ch in text {
            if ch.isWhitespace {
                pendingSpace = count > 0
                continue
            }
            if pendingSpace {
                result.append(" ")
                count += 1
                pendingSpace = false
            }
            result.append(ch)
            count += 1
            if count >= limit {
                result.append("…")
                break
            }
        }
        return result
    }

    static func hash(_ reps: [Representation]) -> String {
        var hasher = SHA256()
        for rep in reps {
            hasher.update(data: Data("\(rep.itemIndex)|\(rep.type)|\(rep.data.count)|".utf8))
            hasher.update(data: rep.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
