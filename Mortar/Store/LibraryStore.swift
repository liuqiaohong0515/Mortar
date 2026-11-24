import Foundation
import SQLite3

final class LibraryStore {
    let databaseURL: URL
    private var db: OpaquePointer?

    init() throws {
        let root = try Self.supportDirectory()
        databaseURL = root.appendingPathComponent("library.sqlite")
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw StoreError.open(databaseURL.path)
        }
        try migrate()
    }

    static func supportDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MORTAR_SUPPORT"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mortar", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func close() { sqlite3_close(db); db = nil }

    func reopen() throws {
        sqlite3_close(db)
        db = nil
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw StoreError.open(databaseURL.path)
        }
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS repositories (
          id TEXT PRIMARY KEY, nickname TEXT, url TEXT, local_path TEXT,
          username TEXT, inaccessible INTEGER, sort_index INTEGER
        );
        CREATE TABLE IF NOT EXISTS working_copies (
          id TEXT PRIMARY KEY, repository_id TEXT, name TEXT, path TEXT,
          inaccessible INTEGER, sort_index INTEGER, local_changes INTEGER, pending_updates INTEGER
        );
        CREATE TABLE IF NOT EXISTS transcripts (
          id TEXT PRIMARY KEY, owner_id TEXT, created REAL, title TEXT, body TEXT, note TEXT, ok INTEGER
        );
        CREATE TABLE IF NOT EXISTS log_cache (
          repo_id TEXT, path TEXT, revision INTEGER, author TEXT, date TEXT, message TEXT, paths_json TEXT,
          PRIMARY KEY (repo_id, path, revision)
        );
        CREATE TABLE IF NOT EXISTS issue_rules (
          id TEXT PRIMARY KEY, repo_id TEXT, pattern TEXT, url_template TEXT
        );
        CREATE TABLE IF NOT EXISTS user_properties (
          id TEXT PRIMARY KEY, name TEXT, label TEXT, type TEXT, options TEXT, enabled INTEGER
        );
        CREATE TABLE IF NOT EXISTS shelves (
          id TEXT PRIMARY KEY, wc_id TEXT, name TEXT, log TEXT, version INTEGER,
          created REAL, patch_path TEXT, checkpoint INTEGER
        );
        CREATE TABLE IF NOT EXISTS session (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS trusted_hosts (host TEXT PRIMARY KEY);
        """)
    }

    func repositories() -> [RepoRecord] { queryRepos("SELECT id,nickname,url,local_path,username,inaccessible,sort_index FROM repositories ORDER BY sort_index, nickname") }
    func workingCopies() -> [WCRecord] { queryWCs("SELECT id,repository_id,name,path,inaccessible,sort_index,local_changes,pending_updates FROM working_copies ORDER BY sort_index, name") }

    func save(repo: RepoRecord) {
        bindExec("INSERT OR REPLACE INTO repositories (id,nickname,url,local_path,username,inaccessible,sort_index) VALUES (?,?,?,?,?,?,?)", strings: [repo.id, repo.nickname, repo.url, repo.localPath, repo.username], ints: [repo.inaccessible ? 1 : 0, repo.sortIndex])
    }

    func save(wc: WCRecord) {
        bindExec("INSERT OR REPLACE INTO working_copies (id,repository_id,name,path,inaccessible,sort_index,local_changes,pending_updates) VALUES (?,?,?,?,?,?,?,?)", strings: [wc.id, wc.repositoryID, wc.name, wc.path], ints: [wc.inaccessible ? 1 : 0, wc.sortIndex, wc.localChanges, wc.pendingUpdates])
    }

    func deleteRepository(_ id: String) {
        exec("DELETE FROM repositories WHERE id = '\(escape(id))'")
        exec("DELETE FROM working_copies WHERE repository_id = '\(escape(id))'")
        exec("DELETE FROM issue_rules WHERE repo_id = '\(escape(id))'")
        exec("DELETE FROM log_cache WHERE repo_id = '\(escape(id))'")
    }

    func deleteWorkingCopy(_ id: String) {
        exec("DELETE FROM working_copies WHERE id = '\(escape(id))'")
        exec("DELETE FROM shelves WHERE wc_id = '\(escape(id))'")
    }

    func addTranscript(owner: String, title: String, body: String, ok: Bool) {
        let id = UUID().uuidString
        run("INSERT INTO transcripts (id,owner_id,created,title,body,note,ok) VALUES (?,?,?,?,?,?,?)", [
            .text(id), .text(owner), .double(Date().timeIntervalSince1970), .text(title), .text(body), .text(""), .int(ok ? 1 : 0),
        ])
        trimTranscripts()
    }

    func transcripts(owner: String) -> [TranscriptRecord] {
        var statement: OpaquePointer?
        var rows: [TranscriptRecord] = []
        if sqlite3_prepare_v2(db, "SELECT id,owner_id,created,title,body,note,ok FROM transcripts WHERE owner_id = ? ORDER BY created DESC", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, owner, -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(readTranscript(statement))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    func setNote(id: String, note: String) {
        bindExec("UPDATE transcripts SET note = ? WHERE id = ?", strings: [note, id])
    }

    func clearTranscripts(owner: String) {
        exec("DELETE FROM transcripts WHERE owner_id = '\(escape(owner))'")
    }

    func cacheLogs(repo: String, path: String, entries: [LogEntry]) {
        for entry in entries {
            let paths = entry.changes.map { "\($0.action)\t\($0.path)\t\($0.copyFromPath)" }.joined(separator: "\n")
            run("INSERT OR REPLACE INTO log_cache (repo_id,path,revision,author,date,message,paths_json) VALUES (?,?,?,?,?,?,?)", [
                .text(repo), .text(path), .int(entry.revision), .text(entry.author),
                .text(ISO8601DateFormatter().string(from: entry.date ?? Date())), .text(entry.message), .text(paths),
            ])
        }
    }

    func cachedLogs(repo: String, path: String) -> [LogEntry] {
        var statement: OpaquePointer?
        var rows: [LogEntry] = []
        if sqlite3_prepare_v2(db, "SELECT revision,author,date,message,paths_json FROM log_cache WHERE repo_id = ? AND path = ? ORDER BY revision DESC", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, repo, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, path, -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                let revision = Int(sqlite3_column_int(statement, 0))
                let author = text(statement, 1)
                let date = ISO8601DateFormatter().date(from: text(statement, 2))
                let message = text(statement, 3)
                let changes = text(statement, 4).split(separator: "\n").compactMap { line -> LogPathChange? in
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 2 else { return nil }
                    return LogPathChange(action: parts[0], kind: "file", path: parts[1], copyFromPath: parts.count > 2 ? parts[2] : "", copyFromRev: "")
                }
                rows.append(LogEntry(revision: revision, author: author, date: date, message: message, changes: changes))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    func clearLogCache(repo: String) { exec("DELETE FROM log_cache WHERE repo_id = '\(escape(repo))'") }

    func issueRules(repo: String) -> [IssueRule] {
        var statement: OpaquePointer?
        var rows: [IssueRule] = []
        if sqlite3_prepare_v2(db, "SELECT id,pattern,url_template FROM issue_rules WHERE repo_id = ?", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, repo, -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(IssueRule(id: text(statement, 0), pattern: text(statement, 1), urlTemplate: text(statement, 2)))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    func saveIssueRules(repo: String, rules: [IssueRule]) {
        exec("DELETE FROM issue_rules WHERE repo_id = '\(escape(repo))'")
        for rule in rules {
            bindExec("INSERT INTO issue_rules (id,repo_id,pattern,url_template) VALUES (?,?,?,?)", strings: [rule.id, repo, rule.pattern, rule.urlTemplate])
        }
    }

    func userProperties() -> [UserPropertyDef] {
        var statement: OpaquePointer?
        var rows: [UserPropertyDef] = []
        if sqlite3_prepare_v2(db, "SELECT id,name,label,type,options,enabled FROM user_properties", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(UserPropertyDef(id: text(statement, 0), name: text(statement, 1), label: text(statement, 2), type: text(statement, 3), options: text(statement, 4), enabled: sqlite3_column_int(statement, 5) == 1))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    func saveUserProperties(_ items: [UserPropertyDef]) {
        exec("DELETE FROM user_properties")
        for item in items {
            bindExec("INSERT INTO user_properties (id,name,label,type,options,enabled) VALUES (?,?,?,?,?,?)", strings: [item.id, item.name, item.label, item.type, item.options], ints: [item.enabled ? 1 : 0])
        }
    }

    func shelves(wc: String) -> [ShelfRecord] {
        var statement: OpaquePointer?
        var rows: [ShelfRecord] = []
        if sqlite3_prepare_v2(db, "SELECT id,wc_id,name,log,version,created,patch_path,checkpoint FROM shelves WHERE wc_id = ? ORDER BY name, version DESC", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, wc, -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(ShelfRecord(
                    id: text(statement, 0), workingCopyID: text(statement, 1), name: text(statement, 2),
                    log: text(statement, 3), version: Int(sqlite3_column_int(statement, 4)),
                    created: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    patchPath: text(statement, 6), checkpoint: sqlite3_column_int(statement, 7) == 1
                ))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    func saveShelf(_ shelf: ShelfRecord) {
        run("INSERT OR REPLACE INTO shelves (id,wc_id,name,log,version,created,patch_path,checkpoint) VALUES (?,?,?,?,?,?,?,?)", [
            .text(shelf.id), .text(shelf.workingCopyID), .text(shelf.name), .text(shelf.log),
            .int(shelf.version), .double(shelf.created.timeIntervalSince1970), .text(shelf.patchPath), .int(shelf.checkpoint ? 1 : 0),
        ])
    }

    func session(_ key: String) -> String? {
        var statement: OpaquePointer?
        var value: String?
        if sqlite3_prepare_v2(db, "SELECT value FROM session WHERE key = ?", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW { value = text(statement, 0) }
        }
        sqlite3_finalize(statement)
        return value
    }

    func setSession(_ key: String, _ value: String) {
        bindExec("INSERT OR REPLACE INTO session (key,value) VALUES (?,?)", strings: [key, value])
    }

    func isTrusted(_ host: String) -> Bool {
        var statement: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, "SELECT host FROM trusted_hosts WHERE host = ?", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, host, -1, SQLITE_TRANSIENT)
            found = sqlite3_step(statement) == SQLITE_ROW
        }
        sqlite3_finalize(statement)
        return found
    }

    func trust(_ host: String) {
        bindExec("INSERT OR REPLACE INTO trusted_hosts (host) VALUES (?)", strings: [host])
    }

    private func trimTranscripts() {
        let retention = UserDefaults.standard.string(forKey: "transcriptRetention") ?? "month"
        let seconds: TimeInterval
        switch retention {
        case "replace": seconds = 0
        case "15m": seconds = 15 * 60
        case "1h": seconds = 3600
        case "1d": seconds = 86400
        case "1w": seconds = 7 * 86400
        default: seconds = 30 * 86400
        }
        if retention == "replace" {
            exec("DELETE FROM transcripts WHERE id NOT IN (SELECT id FROM transcripts ORDER BY created DESC LIMIT 1)")
            return
        }
        let cutoff = Date().timeIntervalSince1970 - seconds
        exec("DELETE FROM transcripts WHERE created < \(cutoff)")
    }

    private func queryRepos(_ sql: String) -> [RepoRecord] {
        var statement: OpaquePointer?
        var rows: [RepoRecord] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(RepoRecord(id: text(statement, 0), nickname: text(statement, 1), url: text(statement, 2), localPath: text(statement, 3), username: text(statement, 4), inaccessible: sqlite3_column_int(statement, 5) == 1, sortIndex: Int(sqlite3_column_int(statement, 6))))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    private func queryWCs(_ sql: String) -> [WCRecord] {
        var statement: OpaquePointer?
        var rows: [WCRecord] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(WCRecord(id: text(statement, 0), repositoryID: text(statement, 1), name: text(statement, 2), path: text(statement, 3), inaccessible: sqlite3_column_int(statement, 4) == 1, sortIndex: Int(sqlite3_column_int(statement, 5)), localChanges: Int(sqlite3_column_int(statement, 6)), pendingUpdates: Int(sqlite3_column_int(statement, 7))))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    private func readTranscript(_ statement: OpaquePointer?) -> TranscriptRecord {
        TranscriptRecord(id: text(statement, 0), ownerID: text(statement, 1), created: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), title: text(statement, 3), body: text(statement, 4), note: text(statement, 5), ok: sqlite3_column_int(statement, 6) == 1)
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite"
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }

    private func exec(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &error)
        sqlite3_free(error)
    }

    private enum SQLValue {
        case text(String)
        case int(Int)
        case double(Double)
    }

    private func bindExec(_ sql: String, strings: [String], doubles: [Double] = [], ints: [Int] = []) {
        var values: [SQLValue] = strings.map { .text($0) }
        values.append(contentsOf: doubles.map { .double($0) })
        values.append(contentsOf: ints.map { .int($0) })
        run(sql, values)
    }

    private func run(_ sql: String, _ values: [SQLValue]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .int(let number):
                sqlite3_bind_int(statement, index, Int32(number))
            case .double(let number):
                sqlite3_bind_double(statement, index, number)
            }
        }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func escape(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct RepoRecord: Identifiable, Equatable {
    var id: String
    var nickname: String
    var url: String
    var localPath: String
    var username: String
    var inaccessible: Bool
    var sortIndex: Int
}

struct WCRecord: Identifiable, Equatable {
    var id: String
    var repositoryID: String
    var name: String
    var path: String
    var inaccessible: Bool
    var sortIndex: Int
    var localChanges: Int
    var pendingUpdates: Int
}

struct TranscriptRecord: Identifiable, Equatable {
    var id: String
    var ownerID: String
    var created: Date
    var title: String
    var body: String
    var note: String
    var ok: Bool
}

struct IssueRule: Identifiable, Equatable {
    var id: String
    var pattern: String
    var urlTemplate: String
}

struct UserPropertyDef: Identifiable, Equatable {
    var id: String
    var name: String
    var label: String
    var type: String
    var options: String
    var enabled: Bool
}

enum StoreError: Error {
    case open(String)
    case sql(String)
}
