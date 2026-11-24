import Foundation

nonisolated enum SVNXML {
    static func status(_ data: Data) -> [StatusEntry] { StatusParser().parse(data) }
    static func list(_ data: Data) -> [ListEntry] { ListParser().parse(data) }
    static func log(_ data: Data) -> [LogEntry] { LogParser().parse(data) }
    static func info(_ data: Data) -> InfoEntry { InfoParser().parse(data) }
    static func blame(_ data: Data) -> [BlameLine] { BlameParser().parse(data) }
    static func properties(_ data: Data) -> [PropertyValue] { PropParser().parse(data) }
}

private nonisolated final class StatusParser: NSObject, XMLParserDelegate {
    private var entries: [StatusEntry] = []
    private var path = ""
    private var item = "normal"
    private var props = "none"
    private var revision = ""
    private var author = ""
    private var date = ""
    private var reposItem = ""
    private var reposRevision = ""
    private var lockOwner = ""
    private var copied = false
    private var switched = false
    private var tree = false
    private var movedFrom = ""
    private var depth = ""
    private var kind = "file"
    private var text = ""
    private var capture = ""
    private var inCommit = false
    private var inRepos = false

    func parse(_ data: Data) -> [StatusEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "entry":
            path = attributes["path"] ?? ""
            kind = attributes["kind"] ?? "file"
            item = "normal"; props = "none"; revision = ""; author = ""; date = ""
            reposItem = ""; reposRevision = ""; lockOwner = ""; movedFrom = ""; depth = ""
            copied = false; switched = false; tree = false; inCommit = false; inRepos = false
        case "wc-status":
            item = attributes["item"] ?? "normal"
            props = attributes["props"] ?? "none"
            revision = attributes["revision"] ?? ""
            copied = attributes["copied"] == "true"
            switched = attributes["switched"] == "true"
            tree = attributes["tree-conflicted"] == "true"
            inRepos = false
        case "repos-status":
            reposItem = attributes["item"] ?? ""
            reposRevision = attributes["revision"] ?? ""
            inRepos = true
        case "commit":
            if !inRepos, revision.isEmpty { revision = attributes["revision"] ?? "" }
            inCommit = true
        case "lock":
            break
        case "moved-from":
            movedFrom = attributes["path"] ?? ""
        default:
            capture = name
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inCommit, !inRepos {
            if name == "author" { author = value }
            if name == "date" { date = value }
        }
        if name == "commit" { inCommit = false }
        if name == "repos-status" { inRepos = false }
        if name == "owner" { lockOwner = value }
        if name == "depth" { depth = value }
        if name == "entry", !path.isEmpty {
            entries.append(StatusEntry(
                path: path, item: item, props: props, revision: revision, author: author,
                date: SVNDate.parse(date), reposItem: reposItem, reposRevision: reposRevision,
                lockOwner: lockOwner, lockToken: "", copied: copied, switched: switched,
                treeConflict: tree, movedFrom: movedFrom, depth: depth, kind: kind
            ))
        }
    }
}

private nonisolated final class ListParser: NSObject, XMLParserDelegate {
    private var entries: [ListEntry] = []
    private var name = ""
    private var kind = "file"
    private var revision = ""
    private var author = ""
    private var date = ""
    private var size: Int64 = 0
    private var text = ""
    private var inCommit = false

    func parse(_ data: Data) -> [ListEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if element == "entry" {
            kind = attributes["kind"] ?? "file"
            name = ""; revision = ""; author = ""; date = ""; size = 0
        } else if element == "commit" {
            revision = attributes["revision"] ?? ""
            inCommit = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "name": name = value
        case "author" where inCommit: author = value
        case "date" where inCommit: date = value
        case "size": size = Int64(value) ?? 0
        case "commit": inCommit = false
        case "entry":
            if !name.isEmpty {
                entries.append(ListEntry(name: name, kind: kind, revision: revision, author: author, date: SVNDate.parse(date), size: size))
            }
        default: break
        }
    }
}

private nonisolated final class LogParser: NSObject, XMLParserDelegate {
    private var entries: [LogEntry] = []
    private var revision = 0
    private var author = ""
    private var date = ""
    private var message = ""
    private var changes: [LogPathChange] = []
    private var text = ""
    private var pathAction = ""
    private var pathKind = ""
    private var copyPath = ""
    private var copyRev = ""

    func parse(_ data: Data) -> [LogEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if element == "logentry" {
            revision = Int(attributes["revision"] ?? "") ?? 0
            author = ""; date = ""; message = ""; changes = []
        } else if element == "path" {
            pathAction = attributes["action"] ?? "M"
            pathKind = attributes["kind"] ?? "file"
            copyPath = attributes["copyfrom-path"] ?? ""
            copyRev = attributes["copyfrom-rev"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "author": author = value
        case "date": date = value
        case "msg": message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "path":
            changes.append(LogPathChange(action: pathAction, kind: pathKind, path: value, copyFromPath: copyPath, copyFromRev: copyRev))
        case "logentry":
            entries.append(LogEntry(revision: revision, author: author, date: SVNDate.parse(date), message: message, changes: changes))
        default: break
        }
    }
}

private nonisolated final class InfoParser: NSObject, XMLParserDelegate {
    private var info = InfoEntry()
    private var text = ""
    private var inCommit = false
    private var inRepo = false

    func parse(_ data: Data) -> InfoEntry {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return info
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if element == "entry" {
            info.kind = attributes["kind"] ?? ""
            info.revision = attributes["revision"] ?? ""
        } else if element == "commit" {
            info.lastChangedRev = attributes["revision"] ?? ""
            inCommit = true
        } else if element == "repository" {
            inRepo = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "url": info.url = value
        case "relative-url": info.relativeURL = value
        case "root" where inRepo: info.repositoryRoot = value
        case "uuid" where inRepo: info.uuid = value
        case "author" where inCommit: info.author = value
        case "date" where inCommit: info.date = SVNDate.parse(value)
        case "wcroot-abspath": info.wcRoot = value
        case "schedule": info.schedule = value
        case "depth": info.depth = value
        case "commit": inCommit = false
        case "repository": inRepo = false
        default: break
        }
    }
}

private nonisolated final class BlameParser: NSObject, XMLParserDelegate {
    private var lines: [BlameLine] = []
    private var line = 0
    private var revision = ""
    private var author = ""
    private var date = ""
    private var text = ""

    func parse(_ data: Data) -> [BlameLine] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return lines
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if element == "entry" {
            line = Int(attributes["line-number"] ?? "") ?? 0
            revision = ""; author = ""; date = ""
        } else if element == "commit" {
            revision = attributes["revision"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if element == "author" { author = value }
        if element == "date" { date = value }
        if element == "entry" {
            lines.append(BlameLine(line: line, revision: revision, author: author, date: SVNDate.parse(date)))
        }
    }
}

private nonisolated final class PropParser: NSObject, XMLParserDelegate {
    private var values: [PropertyValue] = []
    private var name = ""
    private var text = ""

    func parse(_ data: Data) -> [PropertyValue] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return values
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if element == "property" { name = attributes["name"] ?? "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "property" {
            values.append(PropertyValue(name: name, value: text))
        }
    }
}
