import Foundation
import CSQLCipher

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum HistoryTab: CaseIterable {
    case history, images, tagged
}

enum SQLValue {
    case int(Int64), double(Double), text(String), blob(Data), null
}

struct StoreError: Error, CustomStringConvertible {
    let description: String
}

final class Store {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "clipsie.store")
    private var prunesSinceVacuum = 0
    private var ftsReady = false
    private static let ftsBatchSize = 500

    init(url: URL, key: Data) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            throw StoreError(description: "Cannot open \(url.path): \(lastError)")
        }
        try exec(DatabaseEncryption.keyPragma(key))
        do {
            try exec("SELECT COUNT(*) FROM sqlite_master")
        } catch {
            if sqlite3_errcode(db) == SQLITE_NOTADB { throw DatabaseEncryption.OpenError.wrongKey }
            throw error
        }
        try exec("""
            PRAGMA auto_vacuum = INCREMENTAL;
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                hash TEXT NOT NULL UNIQUE,
                kind INTEGER NOT NULL,
                preview TEXT NOT NULL,
                source_app TEXT,
                byte_size INTEGER NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                used_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS items_order ON items(pinned DESC, used_at DESC);
            CREATE TABLE IF NOT EXISTS item_text (
                item_id INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                search TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS item_data (
                item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                item_index INTEGER NOT NULL,
                type TEXT NOT NULL,
                data BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS item_data_item ON item_data(item_id);
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            CREATE TABLE IF NOT EXISTS item_thumb (
                item_id INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                data BLOB NOT NULL
            );
            """)
        try migrate()
        try setUpSearchIndex()
        backfillThumbnails()
    }

    private func setUpSearchIndex() throws {
        let available = (try? exec("""
            CREATE VIRTUAL TABLE temp.fts_probe USING fts5(x, tokenize='trigram');
            DROP TABLE temp.fts_probe;
            """)) != nil
        guard available else {
            NSLog("Clipsie: SQLite \(String(cString: sqlite3_libversion())) has no FTS5 trigram support; search scans the history")
            try exec("""
                DROP TRIGGER IF EXISTS item_fts_insert;
                DROP TRIGGER IF EXISTS item_fts_update;
                DROP TRIGGER IF EXISTS item_fts_delete;
                DELETE FROM meta WHERE key = 'fts_indexed_to';
                """)
            return
        }
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS item_fts USING fts5(search, tokenize='trigram', detail='none');
            CREATE TRIGGER IF NOT EXISTS item_fts_insert AFTER INSERT ON item_text BEGIN
                INSERT INTO item_fts(rowid, search) VALUES (new.item_id, new.search);
            END;
            CREATE TRIGGER IF NOT EXISTS item_fts_update AFTER UPDATE OF search ON item_text BEGIN
                DELETE FROM item_fts WHERE rowid = old.item_id;
                INSERT INTO item_fts(rowid, search) VALUES (new.item_id, new.search);
            END;
            CREATE TRIGGER IF NOT EXISTS item_fts_delete AFTER DELETE ON item_text BEGIN
                DELETE FROM item_fts WHERE rowid = old.item_id;
            END;
            """)
        var indexedTo: String?
        try run("SELECT value FROM meta WHERE key = 'fts_indexed_to'") { indexedTo = self.text($0, 0) }
        if indexedTo == "done" {
            ftsReady = true
        } else {
            if indexedTo == nil { try exec("DELETE FROM item_fts") }
            queue.async { self.indexNextBatch(after: Int64(indexedTo ?? "") ?? 0) }
        }
    }

    private func indexNextBatch(after cursor: Int64) {
        attempt {
            var batchEnd: Int64?
            try run("SELECT MAX(item_id) FROM (SELECT item_id FROM item_text WHERE item_id > ? ORDER BY item_id LIMIT ?)",
                    [.int(cursor), .int(Int64(Self.ftsBatchSize))]) { stmt in
                if sqlite3_column_type(stmt, 0) != SQLITE_NULL { batchEnd = sqlite3_column_int64(stmt, 0) }
            }
            guard let last = batchEnd else {
                try run("INSERT OR REPLACE INTO meta (key, value) VALUES ('fts_indexed_to', 'done')")
                ftsReady = true
                return
            }
            try transaction {
                try run("""
                    INSERT INTO item_fts(rowid, search) SELECT item_id, search FROM item_text t
                    WHERE item_id > ? AND item_id <= ? AND NOT EXISTS (SELECT 1 FROM item_fts f WHERE f.rowid = t.item_id)
                    """, [.int(cursor), .int(last)])
                try run("INSERT OR REPLACE INTO meta (key, value) VALUES ('fts_indexed_to', ?)", [.text(String(last))])
            }
            queue.async { self.indexNextBatch(after: last) }
        }
    }

    private func migrate() throws {
        var columns = Set<String>()
        try run("PRAGMA table_info(items)") { stmt in
            if let name = self.text(stmt, 1) { columns.insert(name) }
        }
        if !columns.contains("in_history") {
            try exec("ALTER TABLE items ADD COLUMN in_history INTEGER NOT NULL DEFAULT 1")
        }
        if !columns.contains("title") {
            try exec("ALTER TABLE items ADD COLUMN title TEXT")
        }
        var tables = Set<String>()
        try run("SELECT name FROM sqlite_master WHERE type = 'table'") { stmt in
            if let name = self.text(stmt, 0) { tables.insert(name) }
        }
        if !tables.contains("tags") {
            try exec("""
                CREATE TABLE tags (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE COLLATE NOCASE
                );
                CREATE TABLE item_tags (
                    item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    tagged_at REAL NOT NULL,
                    PRIMARY KEY (item_id, tag_id)
                ) WITHOUT ROWID;
                CREATE INDEX item_tags_tag ON item_tags(tag_id);
                INSERT INTO tags (name) VALUES ('\(Self.importantTag)');
                """)
        }
        if columns.contains("important_at") {
            try transaction {
                try exec("""
                    INSERT OR IGNORE INTO tags (name) VALUES ('\(Self.importantTag)');
                    INSERT OR IGNORE INTO item_tags (item_id, tag_id, tagged_at)
                        SELECT id, (SELECT id FROM tags WHERE name = '\(Self.importantTag)'), important_at
                        FROM items WHERE important_at IS NOT NULL;
                    DROP INDEX IF EXISTS items_important;
                    ALTER TABLE items DROP COLUMN important_at;
                    """)
            }
        }
        if columns.contains("snippet_at") {
            try transaction {
                try exec("""
                    UPDATE items SET in_history = 1 WHERE snippet_at IS NOT NULL;
                    DROP INDEX IF EXISTS items_snippets;
                    ALTER TABLE items DROP COLUMN snippet_at;
                    """)
            }
        }
        var textColumns = Set<String>()
        try run("PRAGMA table_info(item_text)") { stmt in
            if let name = self.text(stmt, 1) { textColumns.insert(name) }
        }
        if !textColumns.contains("ocr") {
            try exec("ALTER TABLE item_text ADD COLUMN ocr TEXT")
        }
    }

    private func backfillThumbnails() {
        queue.async {
            let types = Content.imageTypes.map { "'\($0)'" }.joined(separator: ",")
            var ids: [Int64] = []
            self.attempt {
                try self.run("""
                    SELECT DISTINCT item_id FROM item_data d WHERE type IN (\(types))
                    AND NOT EXISTS (SELECT 1 FROM item_thumb t WHERE t.item_id = d.item_id)
                    """) { ids.append(sqlite3_column_int64($0, 0)) }
            }
            for id in ids {
                self.queue.async {
                    let thumbnail = Content.imageData(self.loadRepresentations(id)).flatMap { Content.thumbnail($0) }
                    self.attempt {
                        try self.run("""
                            INSERT OR REPLACE INTO item_thumb (item_id, data)
                            SELECT ?, ? WHERE EXISTS (SELECT 1 FROM items WHERE id = ?)
                            """, [.int(id), .blob(thumbnail ?? Data()), .int(id)])
                    }
                }
            }
        }
    }

    deinit {
        sqlite3_close(db)
    }

    @discardableResult
    func save(_ capture: Capture, maxItems: Int) -> Int64? {
        queue.sync {
            do {
                let id = try transaction { try upsert(capture) }
                try pruneLocked(maxItems: maxItems)
                return id
            } catch {
                NSLog("Clipsie: save failed: \(error)")
                return nil
            }
        }
    }

    func prune(maxItems: Int) {
        queue.sync { attempt { try pruneLocked(maxItems: maxItems) } }
    }

    func ids(matching query: String, in tab: HistoryTab) -> [Int64] {
        queue.sync { (try? searchIDs(query, tab)) ?? [] }
    }

    func ids(matching query: String, in tab: HistoryTab, completion: @escaping ([Int64]) -> Void) {
        queue.async {
            let ids = (try? self.searchIDs(query, tab)) ?? []
            DispatchQueue.main.async { completion(ids) }
        }
    }

    func rows(ids: [Int64]) -> [ItemRow] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return queue.sync {
            var rows: [ItemRow] = []
            attempt {
                try run("""
                    SELECT \(Self.rowColumns) FROM \(Self.rowSource) WHERE items.id IN (\(placeholders))
                    """, ids.map { .int($0) }) { rows.append(self.row(from: $0)) }
            }
            return rows
        }
    }

    func recentRows(limit: Int, in tab: HistoryTab) -> [ItemRow] {
        let sql = "SELECT \(Self.rowColumns) FROM \(Self.rowSource) WHERE \(Self.filter(tab)) ORDER BY \(Self.order(tab)) LIMIT ?"
        return queue.sync {
            var rows: [ItemRow] = []
            attempt {
                try run(sql, [.int(Int64(limit))]) { rows.append(self.row(from: $0)) }
            }
            return rows
        }
    }

    func recentTexts(limit: Int) -> [String] {
        queue.sync {
            var ids: [Int64] = []
            attempt {
                try run("SELECT id FROM items WHERE in_history = 1 AND kind IN (?, ?, ?) ORDER BY used_at DESC LIMIT ?",
                        [.int(Int64(ItemKind.text.rawValue)), .int(Int64(ItemKind.richText.rawValue)),
                         .int(Int64(ItemKind.files.rawValue)), .int(Int64(limit))]) { ids.append(sqlite3_column_int64($0, 0)) }
            }
            return ids.compactMap { Content.text(loadRepresentations($0)) }
        }
    }

    func latestID() -> Int64? {
        queue.sync {
            var id: Int64?
            attempt {
                try run("SELECT id FROM items WHERE in_history = 1 ORDER BY used_at DESC LIMIT 1") { id = sqlite3_column_int64($0, 0) }
            }
            return id
        }
    }

    func representations(for id: Int64) -> [Representation] {
        queue.sync { loadRepresentations(id) }
    }

    func representations(for id: Int64, completion: @escaping ([Representation]) -> Void) {
        queue.async {
            let reps = self.loadRepresentations(id)
            DispatchQueue.main.async { completion(reps) }
        }
    }

    func touch(_ id: Int64) {
        queue.sync {
            attempt {
                try run("UPDATE items SET used_at = ?, in_history = 1 WHERE id = ?",
                        [.double(Date().timeIntervalSince1970), .int(id)])
            }
        }
    }

    func setPinned(_ id: Int64, _ pinned: Bool) {
        queue.sync {
            attempt { try run("UPDATE items SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .int(id)]) }
        }
    }

    static let importantTag = "important"

    static func tagName(_ raw: String) -> String? {
        let words = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@,").union(.whitespacesAndNewlines))
            .split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: "-")
    }

    func setTags(_ id: Int64, _ names: [String]) {
        let names = names.compactMap(Self.tagName)
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
        queue.sync {
            attempt {
                try transaction {
                    try run("DELETE FROM item_tags WHERE item_id = ? AND tag_id NOT IN (SELECT id FROM tags WHERE name IN (\(placeholders)))",
                            [.int(id)] + names.map { .text($0) })
                    try addTags(names, to: id, at: Date().timeIntervalSince1970)
                    try deleteUnusedTags()
                    try deleteOrphans()
                }
            }
        }
    }

    func allTags() -> [String] {
        queue.sync {
            var names: [String] = []
            attempt {
                try run("SELECT name FROM tags ORDER BY name COLLATE NOCASE") { stmt in
                    if let name = self.text(stmt, 0) { names.append(name) }
                }
            }
            return names
        }
    }

    func removeDuplicates(completion: @escaping (Int) -> Void) {
        queue.async {
            var removed = 0
            self.attempt {
                var candidates: [Int64] = []
                try self.run("""
                    SELECT t.item_id FROM item_text t JOIN items ON items.id = t.item_id
                    WHERE items.kind != ? AND t.search IN (
                        SELECT search FROM item_text WHERE search != '' GROUP BY search HAVING COUNT(*) > 1)
                    ORDER BY items.used_at DESC
                    """, [.int(Int64(ItemKind.image.rawValue))]) { candidates.append(sqlite3_column_int64($0, 0)) }
                var newest: [String: Int64] = [:]
                try self.transaction {
                    for id in candidates {
                        let reps = self.loadRepresentations(id)
                        guard Content.imageData(reps) == nil, let text = Content.text(reps) else { continue }
                        guard let keep = newest[text] else {
                            newest[text] = id
                            continue
                        }
                        try self.run("""
                            UPDATE items SET pinned = MAX(pinned, (SELECT pinned FROM items WHERE id = ?2)),
                                in_history = MAX(in_history, (SELECT in_history FROM items WHERE id = ?2)),
                                created_at = MIN(created_at, (SELECT created_at FROM items WHERE id = ?2)),
                                title = COALESCE(NULLIF(title, ''), (SELECT title FROM items WHERE id = ?2))
                            WHERE id = ?1
                            """, [.int(keep), .int(id)])
                        try self.run("""
                            INSERT OR IGNORE INTO item_tags (item_id, tag_id, tagged_at)
                            SELECT ?, tag_id, tagged_at FROM item_tags WHERE item_id = ?
                            """, [.int(keep), .int(id)])
                        try self.run("DELETE FROM items WHERE id = ?", [.int(id)])
                        removed += 1
                    }
                }
            }
            DispatchQueue.main.async { completion(removed) }
        }
    }

    private static var imageTypeList: String { Content.imageTypes.map { "'\($0)'" }.joined(separator: ",") }

    func idsNeedingOCR() -> [Int64] {
        queue.sync {
            var ids: [Int64] = []
            attempt {
                try run("""
                    SELECT t.item_id FROM item_text t WHERE t.ocr IS NULL AND EXISTS (
                        SELECT 1 FROM item_data d WHERE d.item_id = t.item_id AND d.type IN (\(Self.imageTypeList)))
                    ORDER BY t.item_id DESC
                    """) { ids.append(sqlite3_column_int64($0, 0)) }
            }
            return ids
        }
    }

    func needsOCR(_ id: Int64) -> Bool {
        queue.sync {
            var needed = false
            attempt {
                try run("""
                    SELECT 1 FROM item_text t WHERE t.item_id = ? AND t.ocr IS NULL AND EXISTS (
                        SELECT 1 FROM item_data d WHERE d.item_id = t.item_id AND d.type IN (\(Self.imageTypeList)))
                    """, [.int(id)]) { _ in needed = true }
            }
            return needed
        }
    }

    func setOCRText(_ id: Int64, _ text: String) {
        let search = String(text.prefix(Content.searchTextLimit)).lowercased()
        queue.sync {
            attempt {
                try run("""
                    UPDATE item_text SET ocr = ?,
                        search = CASE WHEN ? = '' THEN search WHEN search = '' THEN ? ELSE search || char(10) || ? END
                    WHERE item_id = ? AND ocr IS NULL
                    """, [.text(text), .text(search), .text(search), .text(search), .int(id)])
            }
        }
    }

    func ocrText(for id: Int64) -> String? {
        queue.sync {
            var text: String?
            attempt {
                try run("SELECT ocr FROM item_text WHERE item_id = ? AND ocr != ''", [.int(id)]) { text = self.text($0, 0) }
            }
            return text
        }
    }

    func setTitle(_ id: Int64, _ title: String?) {
        queue.sync {
            attempt { try run("UPDATE items SET title = ? WHERE id = ?", [title.map { .text($0) } ?? .null, .int(id)]) }
        }
    }

    func remove(_ id: Int64, from tab: HistoryTab) {
        queue.sync {
            attempt {
                switch tab {
                case .history, .images: try run("UPDATE items SET in_history = 0, pinned = 0 WHERE id = ?", [.int(id)])
                case .tagged:
                    try run("DELETE FROM item_tags WHERE item_id = ?", [.int(id)])
                    try deleteUnusedTags()
                }
                try deleteOrphans()
            }
        }
    }

    func clear(keepPinned: Bool) {
        queue.sync {
            attempt {
                try run(keepPinned ? "UPDATE items SET in_history = 0 WHERE pinned = 0"
                                   : "UPDATE items SET in_history = 0, pinned = 0")
                try deleteOrphans()
                try exec("PRAGMA incremental_vacuum")
            }
        }
    }

    func replace(id: Int64, with capture: Capture, moveToTop: Bool = true) {
        queue.sync {
            attempt {
                try transaction {
                    try run("DELETE FROM items WHERE hash = ? AND id != ?", [.text(capture.hash), .int(id)])
                    try run("""
                        UPDATE items SET hash = ?, kind = ?, preview = ?, byte_size = ?, used_at = COALESCE(?, used_at)
                        WHERE id = ?
                        """, [.text(capture.hash), .int(Int64(capture.kind.rawValue)), .text(capture.preview),
                              .int(Int64(capture.byteSize)), moveToTop ? .double(Date().timeIntervalSince1970) : .null,
                              .int(id)])
                    try run("DELETE FROM item_text WHERE item_id = ?", [.int(id)])
                    try run("DELETE FROM item_data WHERE item_id = ?", [.int(id)])
                    try run("DELETE FROM item_thumb WHERE item_id = ?", [.int(id)])
                    try insertContent(id, capture)
                }
            }
        }
    }

    func importItems(_ items: [ImportedItem]) -> (added: Int, merged: Int)? {
        queue.sync {
            var counts = (added: 0, merged: 0)
            do {
                try transaction {
                    for item in items {
                        let capture = item.capture
                        let title = item.title.map { SQLValue.text($0) } ?? .null
                        let source = capture.sourceApp.map { SQLValue.text($0) } ?? .null
                        var existing: Int64?
                        try run("SELECT id FROM items WHERE hash = ?", [.text(capture.hash)]) { existing = sqlite3_column_int64($0, 0) }
                        if let id = existing {
                            try run("""
                                UPDATE items SET used_at = MAX(used_at, ?), created_at = MIN(created_at, ?),
                                    pinned = MAX(pinned, ?), in_history = MAX(in_history, ?),
                                    title = COALESCE(NULLIF(title, ''), ?), source_app = COALESCE(source_app, ?)
                                WHERE id = ?
                                """, [.double(item.usedAt), .double(item.createdAt), .int(item.pinned ? 1 : 0),
                                      .int(item.inHistory ? 1 : 0), title, source, .int(id)])
                            try addTags(item.tags, to: id, at: item.usedAt)
                            counts.merged += 1
                            continue
                        }
                        try run("""
                            INSERT INTO items (hash, kind, preview, source_app, byte_size, pinned, created_at, used_at,
                                               in_history, title)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, [.text(capture.hash), .int(Int64(capture.kind.rawValue)), .text(capture.preview), source,
                                  .int(Int64(capture.byteSize)), .int(item.pinned ? 1 : 0), .double(item.createdAt),
                                  .double(item.usedAt), .int(item.inHistory ? 1 : 0), title])
                        let id = sqlite3_last_insert_rowid(db)
                        try insertContent(id, capture)
                        try addTags(item.tags, to: id, at: item.usedAt)
                        counts.added += 1
                    }
                }
            } catch {
                NSLog("Clipsie: import failed: \(error)")
                return nil
            }
            return counts
        }
    }

    func exportJSON(to url: URL, allFormats: Bool, completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async {
            let result = Result { try self.writeExport(to: url, allFormats: allFormats) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func writeExport(to url: URL, allFormats: Bool) throws -> Int {
        struct Meta {
            let id: Int64, kind: Int, source: String?, title: String?, pinned: Bool, inHistory: Bool
            let created: Double, used: Double, tags: [String]
        }
        var items: [Meta] = []
        try run("""
            SELECT id, kind, source_app, title, pinned, in_history, created_at, used_at, \(Self.tagsColumn)
            FROM items ORDER BY used_at DESC
            """) { stmt in
            items.append(Meta(id: sqlite3_column_int64(stmt, 0), kind: Int(sqlite3_column_int64(stmt, 1)),
                              source: self.text(stmt, 2), title: self.text(stmt, 3),
                              pinned: sqlite3_column_int64(stmt, 4) != 0, inHistory: sqlite3_column_int64(stmt, 5) != 0,
                              created: sqlite3_column_double(stmt, 6), used: sqlite3_column_double(stmt, 7),
                              tags: self.tags(stmt, 8)))
        }

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw StoreError(description: "Cannot create \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let dates = ISO8601DateFormatter()
        func date(_ seconds: Double) -> String { dates.string(from: Date(timeIntervalSince1970: seconds)) }

        let header: [String: Any] = ["version": 1, "exportedAt": date(Date().timeIntervalSince1970), "count": items.count]
        let headerJSON = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        try handle.write(contentsOf: headerJSON.dropLast())
        try handle.write(contentsOf: Data(",\"items\":[\n".utf8))
        for (index, item) in items.enumerated() {
            let reps = loadRepresentations(item.id)
            var object: [String: Any] = [
                "id": item.id,
                "kind": String(describing: ItemKind(rawValue: item.kind) ?? .other),
                "formats": Content.typeSummary(reps),
                "inHistory": item.inHistory,
                "pinned": item.pinned,
                "tags": item.tags,
                "createdAt": date(item.created),
                "usedAt": date(item.used),
            ]
            let text = Content.text(reps)
            object["text"] = text
            object["title"] = item.title
            object["sourceApp"] = item.source
            if allFormats || text == nil || Content.imageData(reps) != nil {
                object["representations"] = reps.map {
                    ["item": $0.itemIndex, "type": $0.type, "base64": $0.data.base64EncodedString()] as [String: Any]
                }
            }
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            if index < items.count - 1 { data.append(contentsOf: Array(",\n".utf8)) }
            try handle.write(contentsOf: data)
        }
        try handle.write(contentsOf: Data("\n]}\n".utf8))
        return items.count
    }

    func count() -> Int {
        queue.sync {
            var count = 0
            attempt { try run("SELECT COUNT(*) FROM items") { count = Int(sqlite3_column_int64($0, 0)) } }
            return count
        }
    }

    private func upsert(_ capture: Capture) throws -> Int64 {
        let now = Date().timeIntervalSince1970
        var existing: Int64?
        try run("SELECT id FROM items WHERE hash = ?", [.text(capture.hash)]) { existing = sqlite3_column_int64($0, 0) }
        if let id = existing {
            try run("UPDATE items SET used_at = ?, in_history = 1, source_app = COALESCE(?, source_app) WHERE id = ?",
                    [.double(now), capture.sourceApp.map { .text($0) } ?? .null, .int(id)])
            return id
        }
        try run("""
            INSERT INTO items (hash, kind, preview, source_app, byte_size, pinned, created_at, used_at)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?)
            """, [.text(capture.hash), .int(Int64(capture.kind.rawValue)), .text(capture.preview),
                  capture.sourceApp.map { .text($0) } ?? .null, .int(Int64(capture.byteSize)),
                  .double(now), .double(now)])
        let id = sqlite3_last_insert_rowid(db)
        try insertContent(id, capture)
        return id
    }

    private func insertContent(_ id: Int64, _ capture: Capture) throws {
        try run("INSERT INTO item_text (item_id, search) VALUES (?, ?)", [.int(id), .text(capture.searchText)])
        for rep in capture.representations {
            try run("INSERT INTO item_data (item_id, item_index, type, data) VALUES (?, ?, ?, ?)",
                    [.int(id), .int(Int64(rep.itemIndex)), .text(rep.type), .blob(rep.data)])
        }
        if let thumbnail = capture.thumbnail {
            try run("INSERT INTO item_thumb (item_id, data) VALUES (?, ?)", [.int(id), .blob(thumbnail)])
        }
    }

    private func pruneLocked(maxItems: Int) throws {
        guard maxItems > 0 else { return }
        try run("""
            UPDATE items SET in_history = 0 WHERE id IN (
                SELECT id FROM items WHERE in_history = 1 AND pinned = 0 ORDER BY used_at DESC LIMIT -1 OFFSET ?
            )
            """, [.int(Int64(maxItems))])
        try deleteOrphans()
        prunesSinceVacuum += 1
        if prunesSinceVacuum >= 500 {
            prunesSinceVacuum = 0
            try exec("PRAGMA incremental_vacuum")
        }
    }

    private func deleteOrphans() throws {
        try run("DELETE FROM items WHERE in_history = 0 AND NOT \(Self.isTagged)")
    }

    private func addTags(_ names: [String], to id: Int64, at time: Double) throws {
        for name in names.compactMap(Self.tagName) {
            try run("INSERT OR IGNORE INTO tags (name) VALUES (?)", [.text(name)])
            try run("INSERT OR IGNORE INTO item_tags (item_id, tag_id, tagged_at) SELECT ?, id, ? FROM tags WHERE name = ?",
                    [.int(id), .double(time), .text(name)])
        }
    }

    private func deleteUnusedTags() throws {
        try run("DELETE FROM tags WHERE name != ? AND NOT EXISTS (SELECT 1 FROM item_tags WHERE tag_id = tags.id)",
                [.text(Self.importantTag)])
    }

    private static let isTagged = "EXISTS (SELECT 1 FROM item_tags WHERE item_id = items.id)"
    private static let tagsColumn =
        "(SELECT group_concat(name, char(10)) FROM item_tags it JOIN tags ON tags.id = it.tag_id WHERE it.item_id = items.id)"
    private static let rowColumns =
        "items.id, kind, preview, source_app, byte_size, pinned, used_at, \(tagsColumn), thumb.data, items.title"
    private static let rowSource = "items LEFT JOIN item_thumb thumb ON thumb.item_id = items.id"

    private static func filter(_ tab: HistoryTab) -> String {
        switch tab {
        case .history: return "in_history = 1"
        case .images: return "in_history = 1 AND kind = \(ItemKind.image.rawValue)"
        case .tagged: return isTagged
        }
    }

    private static func order(_ tab: HistoryTab) -> String {
        switch tab {
        case .tagged: return "(SELECT MAX(tagged_at) FROM item_tags WHERE item_id = items.id) DESC"
        case .history, .images: return "pinned DESC, used_at DESC"
        }
    }

    private func searchIDs(_ query: String, _ tab: HistoryTab) throws -> [Int64] {
        let search = SearchQuery(query)
        var conditions = [Self.filter(tab)]
        var params: [SQLValue] = []
        let titleMatch = "instr(lower(COALESCE(items.title, '')), ?) > 0"
        var scansText = false
        for term in search.terms {
            if ftsReady && term.unicodeScalars.count >= 3 {
                conditions.append("(items.id IN (SELECT rowid FROM item_fts WHERE search LIKE ? AND instr(search, ?) > 0)"
                    + " OR \(titleMatch))")
                params += [SQLValue.text("%" + term + "%"), .text(term), .text(term)]
            } else {
                scansText = true
                conditions.append("(instr(t.search, ?) > 0 OR \(titleMatch))")
                params += [SQLValue.text(term), .text(term)]
            }
        }
        if !search.apps.isEmpty {
            let bundleIDs = try sourceApps().filter { id in search.apps.contains { SearchQuery.app(id, matches: $0) } }
            let placeholders = Array(repeating: "?", count: bundleIDs.count).joined(separator: ",")
            conditions.append(bundleIDs.isEmpty ? "0" : "source_app IN (\(placeholders))")
            params += bundleIDs.map { SQLValue.text($0) }
        }
        if !search.types.isEmpty {
            conditions.append("(" + search.types.map(Self.typeCondition).joined(separator: " OR ") + ")")
        }
        conditions += search.flags.map(Self.flagCondition)
        for tag in search.tags {
            conditions.append("items.id IN (SELECT item_id FROM item_tags JOIN tags ON tags.id = tag_id"
                + " WHERE instr(lower(tags.name), ?) = 1)")
            params.append(.text(tag))
        }
        if let after = search.after {
            conditions.append("used_at >= ?")
            params.append(.double(after.timeIntervalSince1970))
        }
        if let before = search.before {
            conditions.append("used_at < ?")
            params.append(.double(before.timeIntervalSince1970))
        }

        var sql = "SELECT id FROM items"
        if scansText || search.types.contains(where: { $0 == .link || $0 == .color }) {
            sql += " JOIN item_text t ON t.item_id = items.id"
        }
        sql += " WHERE " + conditions.joined(separator: " AND ") + " ORDER BY " + Self.order(tab)
        var ids: [Int64] = []
        try run(sql, params) { ids.append(sqlite3_column_int64($0, 0)) }
        return ids
    }

    private func sourceApps() throws -> [String] {
        var apps: [String] = []
        try run("SELECT DISTINCT source_app FROM items WHERE source_app IS NOT NULL") { stmt in
            if let app = self.text(stmt, 0) { apps.append(app) }
        }
        return apps
    }

    private static let trimmedText = "trim(t.search, ' ' || char(9) || char(10) || char(13))"

    private static func typeCondition(_ type: SearchQuery.ContentType) -> String {
        let text = "kind IN (\(ItemKind.text.rawValue), \(ItemKind.richText.rawValue))"
        let s = trimmedText
        switch type {
        case .text: return text
        case .rich: return "kind = \(ItemKind.richText.rawValue)"
        case .image: return "kind = \(ItemKind.image.rawValue)"
        case .file: return "kind = \(ItemKind.files.rawValue)"
        case .other: return "kind = \(ItemKind.other.rawValue)"
        case .link:
            return "(\(text) AND (\(s) GLOB 'http://?*' OR \(s) GLOB 'https://?*')"
                + " AND \(s) NOT GLOB ('*[' || ' ' || char(9) || char(10) || char(13) || ']*'))"
        case .color:
            let hex = [3, 4, 6, 8].map { "\(s) GLOB '#" + String(repeating: "[0-9a-f]", count: $0) + "'" }
            let function = ["rgb", "rgba", "hsl", "hsla"].map { "\(s) GLOB '\($0)(*)'" }
            return "(\(text) AND (" + hex.joined(separator: " OR ")
                + " OR (length(\(s)) <= 40 AND (" + function.joined(separator: " OR ") + "))))"
        }
    }

    private static func flagCondition(_ flag: SearchQuery.Flag) -> String {
        switch flag {
        case .pinned: return "pinned = 1"
        case .tagged: return isTagged
        case .titled: return "COALESCE(items.title, '') != ''"
        }
    }

    private func loadRepresentations(_ id: Int64) -> [Representation] {
        var reps: [Representation] = []
        attempt {
            try run("SELECT item_index, type, data FROM item_data WHERE item_id = ? ORDER BY item_index, rowid",
                    [.int(id)]) { stmt in
                reps.append(Representation(itemIndex: Int(sqlite3_column_int64(stmt, 0)),
                                           type: self.text(stmt, 1) ?? "",
                                           data: self.blob(stmt, 2)))
            }
        }
        return reps
    }

    private func row(from stmt: OpaquePointer) -> ItemRow {
        ItemRow(id: sqlite3_column_int64(stmt, 0),
                kind: ItemKind(rawValue: Int(sqlite3_column_int64(stmt, 1))) ?? .other,
                preview: text(stmt, 2) ?? "",
                sourceApp: text(stmt, 3),
                byteSize: Int(sqlite3_column_int64(stmt, 4)),
                pinned: sqlite3_column_int64(stmt, 5) != 0,
                usedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                tags: tags(stmt, 7),
                thumbnail: sqlite3_column_bytes(stmt, 8) > 0 ? blob(stmt, 8) : nil,
                title: text(stmt, 9))
    }

    private func tags(_ stmt: OpaquePointer, _ column: Int32) -> [String] {
        (text(stmt, column) ?? "").split(separator: "\n").map(String.init)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { NSLog("Clipsie: database error: \(error)") }
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &message) != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? lastError
            sqlite3_free(message)
            throw StoreError(description: text)
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ params: [SQLValue] = [], _ onRow: (OpaquePointer) -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            throw StoreError(description: "\(lastError) in: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in params.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, index, v)
            case .double(let v): sqlite3_bind_double(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                if v.isEmpty {
                    sqlite3_bind_zeroblob(stmt, index, 0)
                } else {
                    v.withUnsafeBytes { buffer in
                        _ = sqlite3_bind_blob(stmt, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                    }
                }
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                onRow(stmt)
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw StoreError(description: "\(lastError) in: \(sql)")
            }
        }
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: pointer)
    }

    private func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, column)))
    }
}
