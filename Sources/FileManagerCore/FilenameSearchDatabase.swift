import Foundation
import SQLite3
import Darwin

private let filenameSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class FilenameSearchDatabase {
    private var connection: OpaquePointer?
    var handle: OpaquePointer { connection! }
    private(set) var hasTrigram = false
    init(url: URL, readOnly: Bool = false) throws {
        if !readOnly {
            let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw FilenameSearchFailure.database(String(cString: strerror(errno))) }
            var info = stat()
            let valid = fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && fchmod(fd, 0o600) == 0
            close(fd)
            guard valid else { throw FilenameSearchFailure.database("The database location must be a writable regular file.") }
        }
        var pointer: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let result = sqlite3_open_v2(url.path, &pointer, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the database."
            if let pointer { sqlite3_close(pointer) }
            throw FilenameSearchFailure.database(message)
        }
        connection = pointer
        sqlite3_busy_timeout(handle, 3_000)
        do {
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
            try execute("""
                CREATE TABLE IF NOT EXISTS entries(path TEXT PRIMARY KEY, name TEXT NOT NULL,
                  folded TEXT NOT NULL, flags INTEGER NOT NULL, non_ascii INTEGER NOT NULL, scan INTEGER NOT NULL, parent_key INTEGER);
                CREATE TABLE IF NOT EXISTS scopes(path TEXT PRIMARY KEY, complete INTEGER NOT NULL DEFAULT 0,
                  warnings INTEGER NOT NULL DEFAULT 0, event_id INTEGER NOT NULL DEFAULT 0,
                  device INTEGER NOT NULL DEFAULT 0, inode INTEGER NOT NULL DEFAULT 0, volume_id TEXT);
                CREATE INDEX IF NOT EXISTS entries_hidden_dirs ON entries(path) WHERE (flags&17)=17;
                """)
            if try scalar("SELECT count(*) FROM pragma_table_info('entries') WHERE name='parent_key'") == 0 {
                // Existing rows are populated by the mandatory activation scan; avoid
                // rewriting a multi-million-row catalog before cached queries can run.
                try execute("ALTER TABLE entries ADD COLUMN parent_key INTEGER")
            }
            try execute("CREATE INDEX IF NOT EXISTS entries_parent_key ON entries(parent_key) WHERE parent_key IS NOT NULL")
            if try scalar("SELECT count(*) FROM pragma_index_info('entries_unicode') WHERE name='non_ascii'") > 0 {
                try execute("DROP INDEX entries_unicode")
            }
            try execute("CREATE INDEX IF NOT EXISTS entries_unicode ON entries(path) WHERE non_ascii=1")
            if try scalar("SELECT count(*) FROM pragma_table_info('scopes') WHERE name='volume_id'") == 0 {
                try execute("ALTER TABLE scopes ADD COLUMN volume_id TEXT")
            }
            let existingFTS = try scalar("SELECT count(*) FROM sqlite_master WHERE name='entry_fts'") > 0
            do {
                try transaction { try execute("""
                    CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(folded, content='entries', content_rowid='rowid', tokenize='trigram case_sensitive 1');
                    CREATE TRIGGER IF NOT EXISTS entry_ai AFTER INSERT ON entries BEGIN
                      INSERT INTO entry_fts(rowid,folded) VALUES(new.rowid,new.folded); END;
                    CREATE TRIGGER IF NOT EXISTS entry_ad AFTER DELETE ON entries BEGIN
                      INSERT INTO entry_fts(entry_fts,rowid,folded) VALUES('delete',old.rowid,old.folded); END;
                    DROP TRIGGER IF EXISTS entry_au;
                    CREATE TRIGGER entry_au AFTER UPDATE ON entries WHEN old.folded != new.folded BEGIN
                      INSERT INTO entry_fts(entry_fts,rowid,folded) VALUES('delete',old.rowid,old.folded);
                      INSERT INTO entry_fts(rowid,folded) VALUES(new.rowid,new.folded); END;
                    """)
                    if !existingFTS { try execute("INSERT INTO entry_fts(entry_fts) VALUES('rebuild')") }
                }
                hasTrigram = true
            } catch {
                // System SQLite builds without the trigram tokenizer still provide correct search.
                // Queries fall back to the scope's filename rows and Foundation verification.
                let reason = error.localizedDescription.lowercased()
                guard reason.contains("no such module: fts5") || reason.contains("no such tokenizer: trigram") else { throw error }
                hasTrigram = false
            }
        } else {
            hasTrigram = (try? scalar("SELECT count(*) FROM sqlite_master WHERE name='entry_fts'")) == 1
        }
        } catch {
            sqlite3_close_v2(pointer); connection = nil
            throw error
        }
    }
    deinit { if let connection { sqlite3_close_v2(connection) } }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func failure() -> Error { FilenameSearchFailure.database(String(cString: sqlite3_errmsg(handle))) }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        value.withCString { _ = sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), filenameSQLiteTransient) }
    }
    func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }
    func flags(at path: String) throws -> Int32? {
        let statement = try prepare("SELECT flags FROM entries WHERE path=?")
        defer { sqlite3_finalize(statement) }
        bind(path, to: statement, at: 1)
        let step = sqlite3_step(statement)
        if step == SQLITE_ROW { return sqlite3_column_int(statement, 0) }
        guard step == SQLITE_DONE else { throw failure() }
        return nil
    }
    func entry(at path: String) throws -> FilenameSearchEntry? {
        let statement = try prepare("SELECT name,flags FROM entries WHERE path=?")
        defer { sqlite3_finalize(statement) }
        bind(path, to: statement, at: 1)
        let step = sqlite3_step(statement)
        if step == SQLITE_ROW { return FilenameSearchEntry(path: path, name: text(statement, 0), flags: sqlite3_column_int(statement, 1)) }
        guard step == SQLITE_DONE else { throw failure() }
        return nil
    }
    func unseenChildren(in path: String, scan: Int64) throws -> [String] {
        let statement = try prepare("SELECT path FROM entries WHERE parent_key=? AND scan<>?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Self.parentKey(for: path)); sqlite3_bind_int64(statement, 2, scan)
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw failure() }
            let candidate = text(statement, 0)
            // The compact hash is only an index accelerator, never an authority for
            // membership. A collision cannot remove another directory's children.
            if (candidate as NSString).deletingLastPathComponent == path { result.append(candidate) }
        }
    }
    static func parentKey(for path: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int64(bitPattern: hash)
    }
    func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    @discardableResult
    func upsert(_ entries: [FilenameSearchEntry], scan: Int64) throws -> Int {
        let statement = try prepare("""
            INSERT INTO entries(path,name,folded,flags,non_ascii,scan,parent_key) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(path) DO NOTHING
            """)
        defer { sqlite3_finalize(statement) }
        let update = try prepare("UPDATE entries SET name=?2,folded=?3,flags=?4,non_ascii=?5,scan=?6,parent_key=?7 WHERE path=?1")
        defer { sqlite3_finalize(update) }
        var inserted = 0
        for entry in entries {
            let folded = entry.name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
            func bindValues(_ statement: OpaquePointer) {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(entry.url.path, to: statement, at: 1); bind(entry.name, to: statement, at: 2)
                bind(folded, to: statement, at: 3)
                sqlite3_bind_int(statement, 4, entry.flags)
                sqlite3_bind_int(statement, 5, entry.name.unicodeScalars.contains(where: { !$0.isASCII }) ? 1 : 0)
                sqlite3_bind_int64(statement, 6, scan)
                sqlite3_bind_int64(statement, 7, Self.parentKey(for: entry.url.deletingLastPathComponent().path))
            }
            bindValues(statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            if sqlite3_changes(handle) != 0 { inserted += 1 }
            else {
                bindValues(update)
                guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
            }
        }
        return inserted
    }
    @discardableResult
    func deleteSubtree(_ path: String, exceptScan: Int64? = nil, preserving: [String] = [], includingRoot: Bool = true) throws -> Int {
        let prefix = filenamePrefix(path)
        var sql = "DELETE FROM entries WHERE (\(includingRoot ? "path=?" : "path=? AND 0") OR (path>=? AND path<?))"
        if exceptScan != nil { sql += " AND scan<>?" }
        for _ in preserving { sql += " AND NOT(path=? OR (path>=? AND path<?))" }
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        bind(path, to: statement, at: 1); bind(prefix.0, to: statement, at: 2); bind(prefix.1, to: statement, at: 3)
        var index: Int32 = 4
        if let exceptScan { sqlite3_bind_int64(statement, index, exceptScan); index += 1 }
        for path in preserving {
            let range = filenamePrefix(path)
            bind(path, to: statement, at: index); bind(range.0, to: statement, at: index + 1); bind(range.1, to: statement, at: index + 2)
            index += 3
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return Int(sqlite3_changes(handle))
    }
    func discardLegacyScope(_ path: String) throws {
        try transaction {
            // Preserve the system symlink itself if a scan of / cataloged it.
            let isTopLevel = URL(fileURLWithPath: path).pathComponents.count == 2
            try deleteSubtree(path, includingRoot: !isTopLevel)
            let statement = try prepare("DELETE FROM scopes WHERE path=?")
            defer { sqlite3_finalize(statement) }
            bind(path, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }

    func saveScope(_ path: String, complete: Bool, warnings: Int, eventID: UInt64, device: UInt64, inode: UInt64, volumeID: String?) throws {
        let statement = try prepare("INSERT OR REPLACE INTO scopes(path,complete,warnings,event_id,device,inode,volume_id) VALUES(?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        bind(path, to: statement, at: 1); sqlite3_bind_int(statement, 2, complete ? 1 : 0)
        sqlite3_bind_int64(statement, 3, Int64(warnings)); sqlite3_bind_int64(statement, 4, Int64(bitPattern: eventID))
        sqlite3_bind_int64(statement, 5, Int64(bitPattern: device)); sqlite3_bind_int64(statement, 6, Int64(bitPattern: inode))
        if let volumeID { bind(volumeID, to: statement, at: 7) } else { sqlite3_bind_null(statement, 7) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    func scopes() throws -> [(String, Bool, Int, UInt64, UInt64, UInt64, String?)] {
        let statement = try prepare("SELECT path,complete,warnings,event_id,device,inode,volume_id FROM scopes")
        defer { sqlite3_finalize(statement) }
        var result: [(String, Bool, Int, UInt64, UInt64, UInt64, String?)] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            result.append((text(statement, 0), sqlite3_column_int(statement, 1) != 0, Int(sqlite3_column_int(statement, 2)),
                           UInt64(bitPattern: sqlite3_column_int64(statement, 3)), UInt64(bitPattern: sqlite3_column_int64(statement, 4)), UInt64(bitPattern: sqlite3_column_int64(statement, 5)), sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : text(statement, 6)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw failure() }
        return result
    }
    func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
