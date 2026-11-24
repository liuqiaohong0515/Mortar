import Foundation

nonisolated struct SVNOutput: Sendable {
    var code: Int32
    var stdout: Data
    var stderr: String
    var command: String
}

nonisolated struct StatusEntry: Sendable, Identifiable, Hashable {
    var path: String
    var item: String
    var props: String
    var revision: String
    var author: String
    var date: Date?
    var reposItem: String
    var reposRevision: String
    var lockOwner: String
    var lockToken: String
    var copied: Bool
    var switched: Bool
    var treeConflict: Bool
    var movedFrom: String
    var depth: String
    var kind: String

    var id: String { path }

    var isDirectory: Bool { kind == "dir" }

    var letter: String {
        switch item {
        case "added": return "A"
        case "conflicted": return "C"
        case "deleted": return "D"
        case "external": return "X"
        case "ignored": return "I"
        case "missing": return "!"
        case "modified", "merged": return "M"
        case "obstructed": return "~"
        case "replaced": return "R"
        case "unversioned": return "?"
        default:
            if switched { return "S" }
            if props != "none" && props != "normal" { return "M" }
            return ""
        }
    }

    var isChanged: Bool {
        ["added", "conflicted", "deleted", "missing", "modified", "merged", "obstructed", "replaced", "unversioned"].contains(item)
            || (props != "none" && props != "normal")
    }

    var isConflict: Bool { item == "conflicted" || props == "conflicted" || treeConflict }
}

nonisolated struct ListEntry: Sendable, Identifiable, Hashable {
    var name: String
    var kind: String
    var revision: String
    var author: String
    var date: Date?
    var size: Int64
    var id: String { name }
    var isDirectory: Bool { kind == "dir" }
}

nonisolated struct LogPathChange: Sendable, Hashable, Identifiable {
    var action: String
    var kind: String
    var path: String
    var copyFromPath: String
    var copyFromRev: String
    var id: String { action + path }
}

nonisolated struct LogEntry: Sendable, Identifiable, Hashable {
    var revision: Int
    var author: String
    var date: Date?
    var message: String
    var changes: [LogPathChange]
    var id: Int { revision }
}

nonisolated struct InfoEntry: Sendable {
    var url: String = ""
    var relativeURL: String = ""
    var repositoryRoot: String = ""
    var uuid: String = ""
    var revision: String = ""
    var kind: String = ""
    var schedule: String = ""
    var depth: String = ""
    var author: String = ""
    var date: Date?
    var wcRoot: String = ""
    var lastChangedRev: String = ""
}

nonisolated struct BlameLine: Sendable, Identifiable {
    var line: Int
    var revision: String
    var author: String
    var date: Date?
    var id: Int { line }
}

nonisolated struct PropertyValue: Sendable, Hashable {
    var name: String
    var value: String
}

nonisolated struct ShelfRecord: Sendable, Identifiable, Hashable {
    var id: String
    var workingCopyID: String
    var name: String
    var log: String
    var version: Int
    var created: Date
    var patchPath: String
    var checkpoint: Bool
}

enum SVNDate {
    nonisolated static func parse(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = text.firstIndex(of: "."), let z = text.firstIndex(of: "Z"), dot < z {
            text = String(text[..<dot]) + "Z"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
