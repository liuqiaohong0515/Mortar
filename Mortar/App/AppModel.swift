import AppKit
import Foundation
import Observation
import UserNotifications

enum Selection: Hashable {
    case none
    case repository(String)
    case workingCopy(String)
}

enum WorkspaceMode: String, CaseIterable {
    case browser, compare, log, timeline, transcript
}

enum WorkspaceSheet: Identifiable {
    case addRepository
    case addWorkingCopy
    case checkout
    case commit
    case update
    case merge
    case branch(Bool)
    case relocate
    case switchURL
    case externals
    case issues
    case shelve
    case unshelve
    case exportLibrary
    case importLibrary
    case about
    case resolve
    case trust(String)
    case password
    case repair
    case note(String)

    var id: String {
        switch self {
        case .addRepository: return "addRepository"
        case .addWorkingCopy: return "addWorkingCopy"
        case .checkout: return "checkout"
        case .commit: return "commit"
        case .update: return "update"
        case .merge: return "merge"
        case .branch(let tag): return tag ? "tag" : "branch"
        case .relocate: return "relocate"
        case .switchURL: return "switch"
        case .externals: return "externals"
        case .issues: return "issues"
        case .shelve: return "shelve"
        case .unshelve: return "unshelve"
        case .exportLibrary: return "exportLibrary"
        case .importLibrary: return "importLibrary"
        case .about: return "about"
        case .resolve: return "resolve"
        case .trust: return "trust"
        case .password: return "password"
        case .repair: return "repair"
        case .note(let id): return "note-\(id)"
        }
    }
}

struct BrowserRow: Identifiable, Hashable {
    var path: String
    var name: String
    var isDirectory: Bool
    var letter: String
    var item: String
    var props: String
    var revision: String
    var author: String
    var date: Date?
    var size: Int64
    var depth: String
    var lock: String
    var containsChanges: Bool
    var switched: Bool
    var copied: Bool
    var movedFrom: String
    var reposItem: String
    var id: String { path }
}

struct CommitItem: Identifiable, Hashable {
    var path: String
    var letter: String
    var included: Bool
    var pairedPath: String
    var id: String { path }
}

struct CompareDocument {
    var path: String
    var leftTitle: String
    var rightTitle: String
    var leftText: String
    var rightText: String
    var leftImage: Data?
    var rightImage: Data?
    var rows: [DiffRow]
    var editable: Bool
    var blame: [BlameLine]
}

@Observable
final class AppModel {
    let library: LibraryStore
    var language: LanguageController
    var preferences: Preferences
    var repositories: [RepoRecord] = []
    var workingCopies: [WCRecord] = []
    var selection: Selection = .none
    var mode: WorkspaceMode = .browser
    var rows: [BrowserRow] = []
    var browserRoot = ""
    var filter = "all"
    var search = ""
    var revisionSpec = "HEAD"
    var showIgnored = false
    var showExternals = true
    var showRepositoryStatus = false
    var showInspector = true
    var selectedPaths: [String] = []
    var logs: [LogEntry] = []
    var selectedLogRevision: Int?
    var transcript: [TranscriptRecord] = []
    var compare: CompareDocument?
    var properties: [PropertyValue] = []
    var info = InfoEntry()
    var busy = false
    var statusLine = ""
    var errorMessage: String?
    var sheet: WorkspaceSheet?
    var logDraft = ""
    var commitItems: [CommitItem] = []
    var backStack: [String] = []
    var forwardStack: [String] = []
    var pendingTrust = ""
    var activity = ""

    init() {
        let store = (try? LibraryStore()) ?? {
            fatalError("Unable to open the Mortar library")
        }()
        library = store
        let loaded = Preferences.load()
        preferences = loaded
        language = LanguageController(code: loaded.language)
        reloadLists()
    }

    func t(_ key: String) -> String { language.t(key) }

    func reloadLists() {
        repositories = library.repositories()
        workingCopies = library.workingCopies()
        updateBadge()
    }

    var selectedRepository: RepoRecord? {
        switch selection {
        case .repository(let id): return repositories.first { $0.id == id }
        case .workingCopy(let id):
            guard let wc = workingCopies.first(where: { $0.id == id }) else { return nil }
            return repositories.first { $0.id == wc.repositoryID }
        case .none: return nil
        }
    }

    var selectedWorkingCopy: WCRecord? {
        if case .workingCopy(let id) = selection { return workingCopies.first { $0.id == id } }
        return nil
    }

    func select(_ selection: Selection) {
        self.selection = selection
        browserRoot = ""
        selectedPaths = []
        mode = .browser
        Task { await refresh() }
    }

    func refresh() async {
        guard !busy else { return }
        if let wc = selectedWorkingCopy {
            await refreshWorkingCopy(wc)
        } else if let repo = selectedRepository {
            await refreshRepository(repo)
        }
        transcript = library.transcripts(owner: ownerID)
    }

    func filteredRows(parent: String) -> [BrowserRow] {
        let prefix = parent.isEmpty ? "" : parent + "/"
        return rows.filter { row in
            let parentPath = (row.path as NSString).deletingLastPathComponent
            let matchesParent = parent.isEmpty ? !row.path.contains("/") : parentPath == parent
            guard matchesParent else { return false }
            if rowPassesFilter(row) { return true }
            return row.isDirectory && rows.contains { $0.path.hasPrefix(row.path + "/") && rowPassesFilter($0) }
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func rowPassesFilter(_ row: BrowserRow) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            let hay = "\(row.name) \(row.author) \(row.revision)".lowercased()
            if !hay.contains(query) { return false }
        }
        switch filter {
        case "changed": return row.letter == "A" || row.letter == "C" || row.letter == "D" || row.letter == "!" || row.letter == "M" || row.letter == "~" || row.letter == "R" || row.letter == "?"
        case "modified": return row.item == "modified" || row.props == "modified"
        case "conflicted": return row.item == "conflicted" || row.props == "conflicted"
        case "missing": return row.item == "missing"
        case "unversioned": return row.item == "unversioned"
        case "switched": return row.switched
        case "locked": return !row.lock.isEmpty
        case "newer": return !row.reposItem.isEmpty && row.reposItem != "none"
        case "today": return row.date.map { Calendar.current.isDateInToday($0) } ?? false
        case "week": return row.date.map { Calendar.current.isDate($0, equalTo: Date(), toGranularity: .weekOfYear) } ?? false
        case "month": return row.date.map { Calendar.current.isDate($0, equalTo: Date(), toGranularity: .month) } ?? false
        case "recent":
            let newest = rows.compactMap { Int($0.revision) }.max() ?? 0
            return Int(row.revision) == newest && newest > 0
        default: return true
        }
    }

    private var ownerID: String {
        switch selection {
        case .repository(let id), .workingCopy(let id): return id
        case .none: return ""
        }
    }

    private func refreshWorkingCopy(_ wc: WCRecord) async {
        var args = ["status", wc.path, "--xml", "-v"]
        if showIgnored { args.append("--no-ignore") }
        if !showExternals { args.append("--ignore-externals") }
        if showRepositoryStatus { args.append("-u") }
        guard let output = await invoke(args: args, repo: repository(for: wc), title: t("action.refresh")) else { return }
        if output.code != 0, output.stdout.isEmpty { return }
        let entries = SVNXML.status(output.stdout)
        let root = URL(fileURLWithPath: wc.path).standardizedFileURL.path
        rows = entries.compactMap { entry in
            let full = entry.path.hasPrefix("/") ? entry.path : root + "/" + entry.path
            let relative = full.hasPrefix(root) ? String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : entry.path
            if relative.isEmpty { return nil }
            let name = (relative as NSString).lastPathComponent
            var isDirectory = ObjCBool(false)
            FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory)
            return BrowserRow(
                path: relative, name: name.isEmpty ? wc.name : name, isDirectory: isDirectory.boolValue,
                letter: entry.letter, item: entry.item, props: entry.props, revision: entry.revision,
                author: entry.author, date: entry.date, size: fileSize(full), depth: entry.depth,
                lock: entry.lockOwner, containsChanges: false, switched: entry.switched,
                copied: entry.copied, movedFrom: entry.movedFrom, reposItem: entry.reposItem
            )
        }
        markContainsChanges()
        var copy = wc
        copy.localChanges = rows.filter { $0.letter != "" && $0.letter != "X" && $0.letter != "I" }.count
        copy.pendingUpdates = rows.filter { !$0.reposItem.isEmpty && $0.reposItem != "none" }.count
        copy.inaccessible = !FileManager.default.fileExists(atPath: wc.path)
        library.save(wc: copy)
        reloadLists()
        if let first = selectedPaths.first {
            await loadInspector(path: wc.path + "/" + first)
        }
    }

    private func markContainsChanges() {
        let changed = Set(rows.filter { $0.letter != "" }.map(\.path))
        rows = rows.map { row in
            var copy = row
            if row.isDirectory {
                copy.containsChanges = changed.contains { $0.hasPrefix(row.path + "/") }
            }
            return copy
        }
    }

    private func refreshRepository(_ repo: RepoRecord) async {
        let url = repositoryURL(repo, path: browserRoot)
        var args = ["list", "--xml", url]
        if revisionSpec != "HEAD", !revisionSpec.isEmpty { args.append(contentsOf: ["-r", revisionSpec]) }
        guard let output = await invoke(args: args, repo: repo, title: t("action.refresh")), output.code == 0 else { return }
        rows = SVNXML.list(output.stdout).map { entry in
            let path = browserRoot.isEmpty ? entry.name : browserRoot + "/" + entry.name
            return BrowserRow(
                path: path, name: entry.name, isDirectory: entry.isDirectory, letter: "", item: "normal",
                props: "none", revision: entry.revision, author: entry.author, date: entry.date,
                size: entry.size, depth: "", lock: "", containsChanges: false, switched: false,
                copied: false, movedFrom: "", reposItem: ""
            )
        }
    }

    func openPath(_ path: String, directory: Bool) {
        if directory {
            backStack.append(browserRoot)
            forwardStack.removeAll()
            browserRoot = path
            if selectedWorkingCopy == nil { Task { await refresh() } }
        } else if selectedWorkingCopy != nil {
            switch preferences.doubleClick {
            case "compare": Task { await compareBase(path: path) }
            case "quicklook": quickLook(path)
            default: openEditor(path)
            }
        }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(browserRoot)
        browserRoot = previous
        Task { await refresh() }
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(browserRoot)
        browserRoot = next
        Task { await refresh() }
    }

    func revealFinder() {
        guard let url = selectedFileURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openTerminal() {
        guard let url = selectedDirectoryURL() else { return }
        let source = "tell application \"Terminal\" to do script \"cd \(shellQuote(url.path))\""
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }

    func openEditor(_ relative: String? = nil) {
        guard let url = selectedFileURL(relative) else { return }
        NSWorkspace.shared.open(url)
    }

    func quickLook(_ relative: String? = nil) {
        guard let url = selectedFileURL(relative) else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func invoke(tool: String = "svn", args: [String], cwd: URL? = nil, repo: RepoRecord? = nil, title: String, reportError: Bool = true) async -> SVNOutput? {
        busy = true
        activity = title
        defer { busy = false; activity = "" }
        let repository = repo ?? selectedRepository
        let password = repository.flatMap { KeychainStore.load(account: $0.id) }
        let username = resolvedUsername(repository)
        let ssh = SSHOptions(port: preferences.sshPort, identityFile: preferences.sshIdentity, sendEnv: preferences.sshSendEnv, acceptNew: true)
        do {
            let output = try await SVNExecutor.shared.run(
                tool: tool, arguments: args, workingDirectory: cwd,
                username: username, password: password,
                trustFailures: repository.map { library.isTrusted($0.url) } ?? false,
                ssh: ssh
            )
            library.addTranscript(owner: ownerID.isEmpty ? (repository?.id ?? "app") : ownerID, title: title, body: output.command + "\n" + output.stderr, ok: output.code == 0)
            transcript = library.transcripts(owner: ownerID)
            if output.code != 0, reportError {
                if Self.isAuthenticationFailure(output.stderr) {
                    if case .password = sheet {} else { sheet = .password }
                } else if output.stderr.localizedCaseInsensitiveContains("certificate") {
                    pendingTrust = output.stderr
                    sheet = .trust(output.stderr)
                } else {
                    errorMessage = t("error.svnFailed") + "\n" + output.stderr
                }
            }
            return output
        } catch {
            errorMessage = t("error.noSVN") + "\n" + error.localizedDescription
            return nil
        }
    }

    func repository(for wc: WCRecord) -> RepoRecord? { repositories.first { $0.id == wc.repositoryID } }

    static func isAuthenticationFailure(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("e215004")
            || text.contains("e170001")
            || text.contains("authentication failed")
            || text.contains("authorization failed")
            || text.contains("no more credentials")
            || text.contains("authentication realm")
    }

    func suggestedUsername() -> String {
        resolvedUsername(selectedRepository)
    }

    private func resolvedUsername(_ repository: RepoRecord?) -> String {
        if let name = repository?.username, !name.isEmpty { return name }
        guard let raw = repository?.url, let user = URL(string: raw)?.user else { return "" }
        return user.removingPercentEncoding ?? user
    }

    func repositoryURL(_ repo: RepoRecord, path: String) -> String {
        let base = repo.url.hasSuffix("/") ? String(repo.url.dropLast()) : repo.url
        if path.isEmpty { return base }
        return base + "/" + path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
    }

    func absolutePath(_ relative: String) -> String? {
        guard let wc = selectedWorkingCopy else { return nil }
        if relative.isEmpty { return wc.path }
        return URL(fileURLWithPath: wc.path).appendingPathComponent(relative).path
    }

    func selectedFileURL(_ relative: String? = nil) -> URL? {
        if let relative, let path = absolutePath(relative) { return URL(fileURLWithPath: path) }
        if let path = selectedPaths.first, let full = absolutePath(path) { return URL(fileURLWithPath: full) }
        if let wc = selectedWorkingCopy { return URL(fileURLWithPath: wc.path) }
        if let repo = selectedRepository, !repo.localPath.isEmpty { return URL(fileURLWithPath: repo.localPath) }
        return nil
    }

    private func selectedDirectoryURL() -> URL? {
        guard let url = selectedFileURL() else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        return url.deletingLastPathComponent()
    }

    private func fileSize(_ path: String) -> Int64 {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func shellQuote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func updateBadge() {
        let count = workingCopies.reduce(0) { $0 + $1.localChanges }
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? formattedCount(count) : nil
    }

    func formattedCount(_ value: Int) -> String {
        value.formatted(.number.locale(language.locale))
    }

    func formattedSize(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    func formattedDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    func browserDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return date.formatted(.relative(presentation: .named).locale(language.locale))
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(language.locale))
    }

    func notify(_ key: String, title: String) {
        let enabled: Bool
        switch key {
        case "checkout": enabled = preferences.notifyCheckout
        case "update": enabled = preferences.notifyUpdate
        case "commit": enabled = preferences.notifyCommit
        case "import": enabled = preferences.notifyImport
        case "export": enabled = preferences.notifyExport
        default: enabled = false
        }
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Mortar"
        content.body = title
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func loadInspector(path: String) async {
        guard let output = await invoke(args: ["info", path, "--xml"], title: t("inspector.title")), output.code == 0 else { return }
        info = SVNXML.info(output.stdout)
        if let props = await invoke(args: ["proplist", path, "-v", "--xml"], title: t("inspector.properties")), props.code == 0 {
            properties = SVNXML.properties(props.stdout)
        }
    }
}
