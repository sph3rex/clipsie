import Foundation

struct ImportedItem {
    let capture: Capture
    let createdAt: Double
    let usedAt: Double
    let pinned: Bool
    let inHistory: Bool
    let tags: [String]
    let title: String?
}

enum HistoryImport {
    struct Summary {
        var added = 0
        var merged = 0
        var skipped: [String: Int] = [:]

        mutating func skip(_ reason: String) { skipped[reason, default: 0] += 1 }
    }

    struct ImportError: Error, CustomStringConvertible {
        let description: String
    }

    private static let batchSize = 100
    private static let itemsLineSuffix = ",\"items\":["

    static func run(from url: URL, into store: Store, maxItemBytes: Int,
                    completion: @escaping (Result<Summary, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try importFile(url, store: store, maxItemBytes: maxItemBytes) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func importFile(_ url: URL, store: Store, maxItemBytes: Int) throws -> Summary {
        var summary = Summary()
        var batch: [ImportedItem] = []
        func flush() {
            guard !batch.isEmpty else { return }
            if let counts = store.importItems(batch) {
                summary.added += counts.added
                summary.merged += counts.merged
            } else {
                summary.skipped[L("database error (see Console)"), default: 0] += batch.count
            }
            batch.removeAll()
        }

        func add(_ object: Any) {
            guard let dictionary = object as? [String: Any] else {
                summary.skip(L("not an item"))
                return
            }
            switch item(from: dictionary, maxItemBytes: maxItemBytes) {
            case .success(let imported): batch.append(imported)
            case .failure(let reason): summary.skip(reason.description)
            }
            if batch.count >= batchSize { flush() }
        }

        let lines = try LineReader(url: url)
        guard let first = lines.next() else { throw ImportError(description: L("The file is empty.")) }
        let header = String(decoding: first, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if header.hasSuffix(itemsLineSuffix) {
            let headerJSON = Data((header.dropLast(itemsLineSuffix.count) + "}").utf8)
            try checkVersion(try? JSONSerialization.jsonObject(with: headerJSON))
            while let line = lines.next() {
                var text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasSuffix(",") { text.removeLast() }
                if text.isEmpty || text == "]}" { continue }
                guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                    summary.skip(L("unreadable line"))
                    continue
                }
                add(object)
            }
        } else {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let root: Any
            do {
                root = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw ImportError(description: L("This isn't a JSON file: %@", error.localizedDescription))
            }
            try checkVersion(root)
            guard let items = (root as? [String: Any])?["items"] as? [Any] ?? root as? [Any] else {
                throw ImportError(description: L("The file has no \"items\" list. Choose a file made with Export as JSON…."))
            }
            items.forEach(add)
        }
        flush()
        return summary
    }

    private static func checkVersion(_ header: Any?) throws {
        guard let version = (header as? [String: Any])?["version"] as? Int else { return }
        if version > 1 {
            throw ImportError(description: L("The file was made by a newer version of Clipsie (format version %@).", String(version)))
        }
    }

    private struct SkipReason: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func item(from object: [String: Any], maxItemBytes: Int) -> Result<ImportedItem, SkipReason> {
        let sourceApp = object["sourceApp"] as? String
        let capture: Capture
        if let encoded = object["representations"] as? [[String: Any]], !encoded.isEmpty {
            var reps: [Representation] = []
            for rep in encoded {
                guard let type = rep["type"] as? String, let base64 = rep["base64"] as? String,
                      let data = Data(base64Encoded: base64) else { return .failure(SkipReason(L("invalid formats data"))) }
                reps.append(Representation(itemIndex: rep["item"] as? Int ?? 0, type: type, data: data))
            }
            capture = Capture(representations: reps, sourceApp: sourceApp)
        } else if let text = object["text"] as? String, !text.isEmpty {
            capture = Capture(text: text, sourceApp: sourceApp)
        } else {
            return .failure(SkipReason(L("no content (exported without formats)")))
        }
        if maxItemBytes > 0, capture.byteSize > maxItemBytes {
            return .failure(SkipReason(L("larger than maxItemBytes")))
        }

        let now = Date().timeIntervalSince1970
        let usedAt = date(object["usedAt"]) ?? now
        let inHistory = object["inHistory"] as? Bool ?? true || object["snippet"] as? Bool == true
        var tags = (object["tags"] as? [Any] ?? []).compactMap { $0 as? String }
        if object["important"] as? Bool == true { tags.append(Store.importantTag) }
        guard inHistory || !tags.isEmpty else {
            return .failure(SkipReason("in no list"))
        }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .success(ImportedItem(capture: capture, createdAt: date(object["createdAt"]) ?? usedAt, usedAt: usedAt,
                                     pinned: inHistory && object["pinned"] as? Bool == true, inHistory: inHistory,
                                     tags: tags, title: title))
    }

    private static let dateFormatter = ISO8601DateFormatter()

    private static func date(_ value: Any?) -> Double? {
        (value as? String).flatMap { dateFormatter.date(from: $0) }?.timeIntervalSince1970
    }
}

private final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var start = 0
    private var atEnd = false
    private static let chunkSize = 1 << 20

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    func next() -> Data? {
        while true {
            if let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[start..<newline])
                start = buffer.index(after: newline)
                return line
            }
            if atEnd {
                guard start < buffer.endIndex else { return nil }
                defer { start = buffer.endIndex }
                return Data(buffer[start...])
            }
            buffer = Data(buffer[start...])
            start = buffer.startIndex
            let chunk = (try? handle.read(upToCount: Self.chunkSize)) ?? nil
            if let chunk, !chunk.isEmpty { buffer.append(chunk) } else { atEnd = true }
        }
    }
}
