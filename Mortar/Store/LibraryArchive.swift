import CryptoKit
import Foundation
import SQLite3

enum LibraryArchive {
    static let format = 1

    static func exportArchive(database: URL, preferences: Preferences, includeSecrets: Bool, passphrase: String, to destination: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mortar-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: database, to: folder.appendingPathComponent("library.sqlite"))
        let prefs = try JSONEncoder().encode(preferences)
        try prefs.write(to: folder.appendingPathComponent("preferences.json"))
        var includes = false
        if includeSecrets {
            let secrets = KeychainStore.allAccounts()
            let payload = try JSONEncoder().encode(secrets)
            let sealed = try seal(payload, passphrase: passphrase)
            try sealed.write(to: folder.appendingPathComponent("credentials.enc"))
            includes = true
        }
        let manifest: [String: Any] = [
            "format": format,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            "includesCredentials": includes,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(to: folder.appendingPathComponent("manifest.json"))
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ArchiveError.pack }
    }

    static func readManifest(at archive: URL) throws -> [String: Any] {
        let folder = try unzip(archive)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try Data(contentsOf: folder.appendingPathComponent("mortar-export").appendingPathComponent("manifest.json"))
        // ditto --keepParent uses the folder name. The unzipped root is the temp folder name.
        return try manifest(in: folder)
    }

    static func importArchive(at archive: URL, database: URL, mode: ImportMode, passphrase: String) throws -> Preferences? {
        let folder = try unzip(archive)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = try payloadRoot(in: folder)
        let manifest = try manifest(at: root.appendingPathComponent("manifest.json"))
        guard (manifest["format"] as? Int) == format || (manifest["format"] as? NSNumber)?.intValue == format else {
            throw ArchiveError.version
        }
        let backup = try LibraryStore.supportDirectory().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: database.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.copyItem(at: database, to: backup.appendingPathComponent("library-\(stamp).sqlite"))
        }
        let incoming = root.appendingPathComponent("library.sqlite")
        if mode == .replace {
            if FileManager.default.fileExists(atPath: database.path) { try FileManager.default.removeItem(at: database) }
            try FileManager.default.copyItem(at: incoming, to: database)
        } else {
            try merge(incoming: incoming, into: database)
        }
        let prefsData = try Data(contentsOf: root.appendingPathComponent("preferences.json"))
        let preferences = try JSONDecoder().decode(Preferences.self, from: prefsData)
        if (manifest["includesCredentials"] as? Bool) == true || (manifest["includesCredentials"] as? NSNumber)?.boolValue == true {
            let sealed = try Data(contentsOf: root.appendingPathComponent("credentials.enc"))
            let payload: Data
            do { payload = try open(sealed, passphrase: passphrase) } catch { throw ArchiveError.passphrase }
            let secrets = try JSONDecoder().decode([String: String].self, from: payload)
            for (account, secret) in secrets { KeychainStore.save(account: account, secret: secret) }
        }
        preferences.save()
        return preferences
    }

    private static func merge(incoming: URL, into destination: URL) throws {
        var source: OpaquePointer?
        var target: OpaquePointer?
        guard sqlite3_open(incoming.path, &source) == SQLITE_OK, sqlite3_open(destination.path, &target) == SQLITE_OK else {
            throw ArchiveError.pack
        }
        defer { sqlite3_close(source); sqlite3_close(target) }
        copyMissing(source, target, "repositories", "id")
        copyMissing(source, target, "working_copies", "id")
        copyMissing(source, target, "issue_rules", "id")
        copyMissing(source, target, "user_properties", "id")
        copyMissing(source, target, "shelves", "id")
    }

    private static func copyMissing(_ source: OpaquePointer?, _ target: OpaquePointer?, _ table: String, _ key: String) {
        var statement: OpaquePointer?
        let sql = "SELECT * FROM \(table)"
        guard sqlite3_prepare_v2(source, sql, -1, &statement, nil) == SQLITE_OK else { return }
        let columns = sqlite3_column_count(statement)
        var names: [String] = []
        for index in 0..<columns { names.append(String(cString: sqlite3_column_name(statement, index))) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let keyIndex = Int32(names.firstIndex(of: key) ?? 0)
            let keyValue = sqlite3_column_text(statement, keyIndex).map { String(cString: $0) } ?? ""
            var check: OpaquePointer?
            var exists = false
            if sqlite3_prepare_v2(target, "SELECT 1 FROM \(table) WHERE \(key) = ? LIMIT 1", -1, &check, nil) == SQLITE_OK {
                sqlite3_bind_text(check, 1, keyValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                exists = sqlite3_step(check) == SQLITE_ROW
            }
            sqlite3_finalize(check)
            if exists { continue }
            let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
            var insert: OpaquePointer?
            if sqlite3_prepare_v2(target, "INSERT INTO \(table) (\(names.joined(separator: ","))) VALUES (\(placeholders))", -1, &insert, nil) == SQLITE_OK {
                for index in 0..<columns {
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER:
                        sqlite3_bind_int64(insert, index + 1, sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT:
                        sqlite3_bind_double(insert, index + 1, sqlite3_column_double(statement, index))
                    case SQLITE_TEXT:
                        sqlite3_bind_text(insert, index + 1, sqlite3_column_text(statement, index), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    default:
                        sqlite3_bind_null(insert, index + 1)
                    }
                }
                sqlite3_step(insert)
            }
            sqlite3_finalize(insert)
        }
        sqlite3_finalize(statement)
    }

    private static func unzip(_ archive: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mortar-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ArchiveError.pack }
        return folder
    }

    private static func payloadRoot(in folder: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for child in children where FileManager.default.fileExists(atPath: child.appendingPathComponent("manifest.json").path) {
            return child
        }
        throw ArchiveError.manifest
    }

    private static func manifest(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ArchiveError.manifest }
        return object
    }

    private static func manifest(in folder: URL) throws -> [String: Any] {
        try manifest(at: try payloadRoot(in: folder).appendingPathComponent("manifest.json"))
    }

    private static func seal(_ payload: Data, passphrase: String) throws -> Data {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = SymmetricKey(data: HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)), salt: salt, info: Data("MortarArchive".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) })
        let box = try AES.GCM.seal(payload, using: key)
        guard let combined = box.combined else { throw ArchiveError.pack }
        return salt + combined
    }

    private static func open(_ data: Data, passphrase: String) throws -> Data {
        guard data.count > 16 else { throw ArchiveError.passphrase }
        let salt = data.prefix(16)
        let combined = data.dropFirst(16)
        let key = SymmetricKey(data: HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)), salt: salt, info: Data("MortarArchive".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) })
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }
}

enum ImportMode { case replace, merge }

enum ArchiveError: Error {
    case pack
    case version
    case manifest
    case passphrase
}
