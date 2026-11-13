import CSQLCipher
import Foundation
import Security

enum DatabaseEncryption {
    enum OpenError: Error, CustomStringConvertible {
        case keyMissing
        case wrongKey
        case keychain(OSStatus)
        case migration(String)

        var description: String {
            switch self {
            case .keyMissing:
                return "The history is encrypted, but its key isn't in your Keychain (item “\(Self.keyLabel)”)."
            case .wrongKey:
                return "The key in your Keychain (item “\(Self.keyLabel)”) doesn't open the history."
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "The Keychain didn't give out the history's key: \(message)"
            case .migration(let message):
                return "Encrypting the existing history failed, so it was left as it was: \(message)"
            }
        }

        static let keyLabel = "Clipsie history key"
    }

    static func prepare(_ url: URL) throws -> Data {
        let existingKey = try Keychain.loadKey()
        switch fileState(url) {
        case .missing:
            return try existingKey ?? Keychain.createKey()
        case .encrypted:
            guard let existingKey else { throw OpenError.keyMissing }
            return existingKey
        case .plaintext:
            let key = try existingKey ?? Keychain.createKey()
            try encrypt(url, key: key)
            return key
        }
    }

    static func moveAside(_ url: URL) throws -> URL {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "")
        let target = url.deletingLastPathComponent().appendingPathComponent("history-unreadable-\(stamp).sqlite")
        try FileManager.default.moveItem(at: url, to: target)
        removeSidecars(of: url)
        return target
    }

    static func keyPragma(_ key: Data) -> String {
        "PRAGMA key = \"x'\(key.map { String(format: "%02x", $0) }.joined())'\";"
    }

    private enum FileState {
        case missing, plaintext, encrypted
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    private static func fileState(_ url: URL) -> FileState {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: sqliteHeader.count)) ?? Data()
        if header.isEmpty { return .missing }
        return header == sqliteHeader ? .plaintext : .encrypted
    }

    private static func encrypt(_ url: URL, key: Data) throws {
        let temporary = url.appendingPathExtension("encrypting")
        remove(temporary)
        do {
            let itemCount = try exportEncrypted(from: url, to: temporary, key: key)
            try verify(temporary, key: key, itemCount: itemCount)
            removeSidecars(of: url)
            guard rename(temporary.path, url.path) == 0 else {
                throw OpenError.migration("cannot replace the database file (errno \(errno))")
            }
            removeSidecars(of: temporary)
        } catch {
            remove(temporary)
            removeSidecars(of: temporary)
            if let error = error as? OpenError { throw error }
            throw OpenError.migration("\(error)")
        }
    }

    private static func exportEncrypted(from url: URL, to target: URL, key: Data) throws -> Int64 {
        let db = try Connection(url)
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let count = try db.int("SELECT COUNT(*) FROM items")
        let version = try db.int("PRAGMA user_version")
        let hexKey = key.map { String(format: "%02x", $0) }.joined()
        let path = target.path.replacingOccurrences(of: "'", with: "''")
        try db.exec("""
            ATTACH DATABASE '\(path)' AS encrypted KEY "x'\(hexKey)'";
            PRAGMA encrypted.auto_vacuum = INCREMENTAL;
            SELECT sqlcipher_export('encrypted');
            PRAGMA encrypted.user_version = \(version);
            DETACH DATABASE encrypted;
            """)
        return count
    }

    private static func verify(_ url: URL, key: Data, itemCount: Int64) throws {
        let db = try Connection(url)
        try db.exec(keyPragma(key))
        let check = try db.text("PRAGMA quick_check")
        guard check == "ok" else { throw OpenError.migration("the encrypted copy failed its check: \(check ?? "?")") }
        let count = try db.int("SELECT COUNT(*) FROM items")
        guard count == itemCount else {
            throw OpenError.migration("the encrypted copy has \(count) items instead of \(itemCount)")
        }
    }

    private static func removeSidecars(of url: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            remove(URL(fileURLWithPath: url.path + suffix))
        }
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private final class Connection {
        private var db: OpaquePointer?

        init(_ url: URL) throws {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                let message = Self.message(db)
                sqlite3_close(db)
                throw OpenError.migration("cannot open \(url.lastPathComponent): \(message)")
            }
        }

        deinit {
            sqlite3_close(db)
        }

        func exec(_ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? Self.message(db)
                sqlite3_free(message)
                throw OpenError.migration(text)
            }
        }

        func int(_ sql: String) throws -> Int64 {
            try value(sql) { sqlite3_column_int64($0, 0) }
        }

        func text(_ sql: String) throws -> String? {
            try value(sql) { sqlite3_column_text($0, 0).map { String(cString: $0) } }
        }

        private func value<T>(_ sql: String, _ read: (OpaquePointer) -> T) throws -> T {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
                throw OpenError.migration("\(Self.message(db)) in: \(sql)")
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw OpenError.migration("\(Self.message(db)) in: \(sql)") }
            return read(stmt)
        }

        private static func message(_ db: OpaquePointer?) -> String {
            db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
        }
    }
}

private enum Keychain {
    private static let service = "local.clipsie.database"
    private static let oldService = "local.clipboard-manager.database"
    private static let account = "history.sqlite"

    private static func query(_ service: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    static func loadKey() throws -> Data? {
        if let key = try loadKey(service) { return key }
        guard let key = try loadKey(oldService) else { return nil }
        try add(key)
        guard try loadKey(service) == key else { throw DatabaseEncryption.OpenError.keychain(errSecDecode) }
        let deleted = SecItemDelete(query(oldService) as CFDictionary)
        if deleted != errSecSuccess { NSLog("Clipsie: the old Keychain item wasn't deleted (\(deleted))") }
        return key
    }

    private static func loadKey(_ service: String) throws -> Data? {
        var request = query(service)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw DatabaseEncryption.OpenError.keychain(errSecDecode)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw DatabaseEncryption.OpenError.keychain(status)
        }
    }

    static func createKey() throws -> Data {
        var key = Data(count: 32)
        let random = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard random == errSecSuccess else { throw DatabaseEncryption.OpenError.keychain(random) }
        try add(key)
        return key
    }

    private static func add(_ key: Data) throws {
        var item = query(service)
        item[kSecValueData] = key
        item[kSecAttrLabel] = DatabaseEncryption.OpenError.keyLabel
        item[kSecAttrDescription] = "Encryption key of the clipboard history database"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DatabaseEncryption.OpenError.keychain(status) }
    }
}
