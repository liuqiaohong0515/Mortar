import AppKit
import Foundation

extension AppModel {
    func addWorkingCopy(at url: URL, forceNetwork: Bool = false) async {
        if !forceNetwork, let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]), values.volumeIsLocal == false {
            sheet = .networkVolume(url.path)
            return
        }
        var info = await invoke(args: ["info", url.path, "--xml"], title: t("action.addWorkingCopy"), reportError: false)
        if info == nil || info?.code != 0 {
            let upgraded = await invoke(args: ["upgrade", url.path], title: t("action.upgrade"), reportError: false)
            guard upgraded?.code == 0 else {
                errorMessage = t("error.svnFailed") + "\n" + (upgraded?.stderr ?? "")
                return
            }
            info = await invoke(args: ["info", url.path, "--xml"], title: t("action.addWorkingCopy"), reportError: false)
        }
        guard let info, info.code == 0 else {
            errorMessage = t("error.notWC")
            return
        }
        errorMessage = nil
        let parsed = SVNXML.info(info.stdout)
        var repo = ensureRepository(url: parsed.repositoryRoot.isEmpty ? parsed.url : parsed.repositoryRoot, nickname: url.lastPathComponent, localPath: "")
        if repo.username.isEmpty, let user = URL(string: parsed.url)?.user ?? URL(string: repo.url)?.user {
            repo.username = user.removingPercentEncoding ?? user
            library.save(repo: repo)
        }
        let record = WCRecord(id: UUID().uuidString, repositoryID: repo.id, name: url.lastPathComponent, path: url.path, inaccessible: false, sortIndex: workingCopies.count, localChanges: 0, pendingUpdates: 0)
        library.save(wc: record)
        reloadLists()
        select(.workingCopy(record.id))
    }

    func addFileRepository(path: String, nickname: String, create: Bool, compatibility: String, standardLayout: Bool) async {
        let folder = URL(fileURLWithPath: path)
        if create {
            try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let output = await invoke(tool: "svnadmin", args: ["create", folder.path], title: t("action.addRepository")), output.code == 0 else { return }
            _ = output
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("format").path, isDirectory: &isDir) || FileManager.default.fileExists(atPath: folder.appendingPathComponent("db").path) else {
            errorMessage = t("error.notRepo")
            return
        }
        let url = URL(fileURLWithPath: folder.path).absoluteString
        let repo = ensureRepository(url: url, nickname: nickname.isEmpty ? folder.lastPathComponent : nickname, localPath: folder.path)
        if create, standardLayout {
            for name in ["trunk", "branches", "tags"] {
                _ = await invoke(args: ["mkdir", url + "/" + name, "-m", "Create \(name)"], repo: repo, title: t("action.newFolder"))
            }
        }
        _ = compatibility
        reloadLists()
        select(.repository(repo.id))
    }

    func addRemoteRepository(url: String, nickname: String, username: String, password: String, savePassword: Bool) {
        let repo = ensureRepository(url: url, nickname: nickname.isEmpty ? url : nickname, localPath: "")
        var copy = repo
        copy.username = username
        library.save(repo: copy)
        if savePassword, !password.isEmpty { KeychainStore.save(account: repo.id, secret: password) }
        reloadLists()
        select(.repository(repo.id))
    }

    func removeSelection() {
        switch selection {
        case .repository(let id):
            library.deleteRepository(id)
            KeychainStore.delete(account: id)
        case .workingCopy(let id):
            library.deleteWorkingCopy(id)
        case .none:
            return
        }
        selection = .none
        rows = []
        reloadLists()
    }

    func checkout(name: String, parent: URL, revision: String, depth: String, externals: Bool) async {
        guard let repo = selectedRepository else { return }
        let destination = parent.appendingPathComponent(name)
        var args = ["checkout", repositoryURL(repo, path: browserRoot), destination.path, "--depth", depth]
        if !revision.isEmpty, revision != "HEAD" { args.append(contentsOf: ["-r", revision]) }
        if !externals { args.append("--ignore-externals") }
        guard let output = await invoke(args: args, repo: repo, title: t("action.checkout")), output.code == 0 else { return }
        let record = WCRecord(id: UUID().uuidString, repositoryID: repo.id, name: name, path: destination.path, inaccessible: false, sortIndex: workingCopies.count, localChanges: 0, pendingUpdates: 0)
        library.save(wc: record)
        reloadLists()
        notify("checkout", title: name)
        select(.workingCopy(record.id))
    }

    func importItems(_ urls: [URL], includeChildren: Bool, useIgnores: Bool, message: String, rename: String) async {
        guard let repo = selectedRepository else { return }
        for url in urls {
            let leaf = urls.count == 1 && !rename.isEmpty ? rename : url.lastPathComponent
            let destination = repositoryURL(repo, path: browserRoot.isEmpty ? leaf : browserRoot + "/" + leaf)
            var args = ["import", url.path, destination, "-m", message.isEmpty ? "Import" : message]
            if !includeChildren { args.append("--depth=files") }
            if !useIgnores { args.append("--no-ignore") }
            _ = await invoke(args: args, repo: repo, title: t("action.import"))
        }
        notify("import", title: t("action.import"))
        await refresh()
    }

    func exportSelection(to folder: URL) async {
        guard let repo = selectedRepository else { return }
        for path in selectedPaths.isEmpty ? [browserRoot] : selectedPaths {
            let name = (path as NSString).lastPathComponent
            let dest = folder.appendingPathComponent(name.isEmpty ? repo.nickname : name)
            _ = await invoke(args: ["export", repositoryURL(repo, path: path), dest.path], repo: repo, title: t("action.export"))
        }
        notify("export", title: t("action.export"))
    }

    func downloadSelection() async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        await exportSelection(to: downloads)
    }

    func update(revision: String, depth: String?, externals: Bool) async {
        guard let wc = selectedWorkingCopy else { return }
        let targets = targetPaths(wc)
        var args = ["update"] + targets
        if !revision.isEmpty, revision != "HEAD" { args.append(contentsOf: ["-r", revision]) }
        if let depth { args.append(contentsOf: ["--set-depth", depth]) }
        if !externals { args.append("--ignore-externals") }
        _ = await invoke(args: args, cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.update"))
        notify("update", title: wc.name)
        if preferences.showTranscriptOnUpdate { mode = .transcript }
        await refresh()
    }

    func prepareCommit() {
        guard let wc = selectedWorkingCopy else { return }
        let changed = rows.filter { $0.letter != "" && $0.letter != "I" && $0.letter != "X" }
        let scope = selectedPaths.isEmpty ? changed.map(\.path) : selectedPaths
        var items = changed.filter { scope.contains($0.path) || scope.isEmpty }.map { row in
            CommitItem(path: row.path, letter: row.letter, included: true, pairedPath: pair(for: row))
        }
        if items.isEmpty { items = changed.map { CommitItem(path: $0.path, letter: $0.letter, included: true, pairedPath: pair(for: $0)) } }
        commitItems = items
        sheet = .commit
    }

    func commit(message: String, unlock: Bool, preScript: String, postScript: String) async {
        guard let wc = selectedWorkingCopy else { return }
        let included = commitItems.filter(\.included)
        if included.contains(where: { $0.letter == "C" }) {
            errorMessage = t("error.conflictBlocksCommit")
            return
        }
        if included.isEmpty { return }
        if !preScript.isEmpty {
            let code = runScript(preScript, wc: wc, revision: "", paths: included.map(\.path), message: message)
            if code != 0 {
                errorMessage = t("error.script")
                return
            }
        }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("mortar-log-\(UUID().uuidString).txt")
        try? message.write(to: logURL, atomically: true, encoding: .utf8)
        var args = ["commit"] + included.map { URL(fileURLWithPath: wc.path).appendingPathComponent($0.path).path } + ["-F", logURL.path]
        if unlock { args.append("--no-unlock") } else { args.append("--no-unlock") }
        if unlock { args.removeAll { $0 == "--no-unlock" } }
        let output = await invoke(args: args, cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.commit"))
        if output?.code == 0 {
            logDraft = ""
            notify("commit", title: wc.name)
            if !postScript.isEmpty {
                let revision = output?.stderr.components(separatedBy: .newlines).first { $0.contains("Committed revision") } ?? ""
                _ = runScript(postScript, wc: wc, revision: revision, paths: included.map(\.path), message: message)
            }
        } else {
            logDraft = message
        }
        sheet = nil
        await refresh()
    }

    func revert(paths: [String]) async {
        guard let wc = selectedWorkingCopy else { return }
        let full = (paths.isEmpty ? selectedPaths : paths).map { URL(fileURLWithPath: wc.path).appendingPathComponent($0).path }
        guard !full.isEmpty else { return }
        _ = await invoke(args: ["revert", "--depth", "infinity"] + full, cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.revert"))
        await refresh()
    }

    func addSelected() async {
        guard let wc = selectedWorkingCopy else { return }
        let paths = selectedPaths.map { URL(fileURLWithPath: wc.path).appendingPathComponent($0).path }
        _ = await invoke(args: ["add", "--depth", "infinity"] + paths, cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.add"))
        await refresh()
    }

    func deleteSelected(trash: Bool) async {
        guard let wc = selectedWorkingCopy else { return }
        let paths = selectedPaths.map { URL(fileURLWithPath: wc.path).appendingPathComponent($0).path }
        var args = ["delete"] + paths
        if !trash { args.append("--keep-local") }
        _ = await invoke(args: args, cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.delete"))
        await refresh()
    }

    func ignoreSelected() async {
        guard let wc = selectedWorkingCopy, let relative = selectedPaths.first, let row = rows.first(where: { $0.path == relative }), row.item == "unversioned" else { return }
        let parent = (relative as NSString).deletingLastPathComponent
        let parentPath = parent.isEmpty ? wc.path : URL(fileURLWithPath: wc.path).appendingPathComponent(parent).path
        let existing = propertiesValue("svn:ignore", path: parentPath)
        let pattern = (relative as NSString).lastPathComponent
        let updated = existing.split(separator: "\n").map(String.init) + [pattern]
        _ = await invoke(args: ["propset", "svn:ignore", updated.joined(separator: "\n"), parentPath], repo: repository(for: wc), title: t("action.ignore"))
        await refresh()
    }

    func move(from: String, to: String) async {
        guard let wc = selectedWorkingCopy else { return }
        let source = URL(fileURLWithPath: wc.path).appendingPathComponent(from).path
        let dest = URL(fileURLWithPath: wc.path).appendingPathComponent(to).path
        _ = await invoke(args: ["move", source, dest], cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.move"))
        await refresh()
    }

    func copyItem(from: String, to: String) async {
        guard let wc = selectedWorkingCopy else { return }
        let source = URL(fileURLWithPath: wc.path).appendingPathComponent(from).path
        let dest = URL(fileURLWithPath: wc.path).appendingPathComponent(to).path
        _ = await invoke(args: ["copy", source, dest], cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.copy"))
        await refresh()
    }

    func rename(_ relative: String, to name: String) async {
        let parent = (relative as NSString).deletingLastPathComponent
        let dest = parent.isEmpty ? name : parent + "/" + name
        await move(from: relative, to: dest)
    }

    func lockSelected(comment: String, steal: Bool) async {
        guard let wc = selectedWorkingCopy else { return }
        let paths = selectedPaths.map { URL(fileURLWithPath: wc.path).appendingPathComponent($0).path }
        var args = ["lock", "-m", comment] + paths
        if steal { args.append("--force") }
        _ = await invoke(args: args, repo: repository(for: wc), title: t("action.lock"))
        await refresh()
    }

    func unlockSelected(force: Bool) async {
        guard let wc = selectedWorkingCopy else { return }
        let paths = selectedPaths.map { URL(fileURLWithPath: wc.path).appendingPathComponent($0).path }
        var args = ["unlock"] + paths
        if force { args.append("--force") }
        _ = await invoke(args: args, repo: repository(for: wc), title: t("action.unlock"))
        await refresh()
    }

    func cleanup() async {
        guard let wc = selectedWorkingCopy else { return }
        _ = await invoke(args: ["cleanup", wc.path], repo: repository(for: wc), title: t("action.cleanup"))
        await refresh()
    }

    func upgradeWorkingCopy() async {
        guard let wc = selectedWorkingCopy else { return }
        _ = await invoke(args: ["upgrade", wc.path], repo: repository(for: wc), title: t("action.upgrade"))
        await refresh()
    }

    func switchURL(_ url: String, revision: String) async {
        guard let wc = selectedWorkingCopy else { return }
        var args = ["switch", url, wc.path]
        if !revision.isEmpty, revision != "HEAD" { args.append(contentsOf: ["-r", revision]) }
        _ = await invoke(args: args, repo: repository(for: wc), title: t("action.switch"))
        await refresh()
    }

    func relocate(to url: String) async {
        guard let wc = selectedWorkingCopy, let repo = repository(for: wc) else { return }
        guard let output = await invoke(args: ["relocate", url, wc.path], repo: repo, title: t("action.relocate")), output.code == 0 else { return }
        _ = output
        var copy = repo
        copy.url = url
        library.save(repo: copy)
        reloadLists()
    }

    func resolve(accept: String) async {
        guard let wc = selectedWorkingCopy else { return }
        let paths = selectedPaths.map { URL(fileURLWithPath: wc.path).appendingPathComponent($0).path }
        _ = await invoke(args: ["resolve", "--accept", accept] + paths, repo: repository(for: wc), title: t("action.resolve"))
        await refresh()
    }

    func resolveWithTool() {
        guard let left = conflictFile(".mine"), let right = conflictFile(".r"), let base = conflictFile(".r0") else {
            let tool = preferences.mergeTool.isEmpty ? "/usr/bin/opendiff" : preferences.mergeTool
            guard let working = selectedFileURL() else { return }
            Process.launchedProcess(launchPath: tool, arguments: [working.path])
            return
        }
        let tool = preferences.mergeTool.isEmpty ? "/usr/bin/opendiff" : preferences.mergeTool
        guard let working = selectedFileURL() else { return }
        Process.launchedProcess(launchPath: tool, arguments: [left, right, "-ancestor", base, "-merge", working.path])
    }

    func compareBase(path: String? = nil) async { await compare(path: path, left: "BASE", right: "WORKING") }
    func compareHead(path: String? = nil) async { await compare(path: path, left: "WORKING", right: "HEAD") }

    func compare(path: String?, left: String, right: String, switchMode: Bool = true) async {
        guard let wc = selectedWorkingCopy else { return }
        let relative = path ?? selectedPaths.first ?? ""
        guard !relative.isEmpty, let full = absolutePath(relative) else { return }
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        if isImage(full) {
            let leftData = await catData(full, revision: left, wc: wc)
            let rightData = right == "WORKING" ? (try? Data(contentsOf: URL(fileURLWithPath: full))) : await catData(full, revision: right, wc: wc)
            compare = CompareDocument(path: relative, leftTitle: left, rightTitle: right, leftText: "", rightText: "", leftImage: leftData, rightImage: rightData, rows: [], editable: false, blame: [])
            if switchMode { mode = .compare }
            return
        }
        let leftText = await cat(full, revision: left, wc: wc)
        let rightText = right == "WORKING" ? (try? String(contentsOfFile: full, encoding: .utf8)) ?? "" : await cat(full, revision: right, wc: wc)
        compare = CompareDocument(
            path: relative, leftTitle: left, rightTitle: right, leftText: leftText, rightText: rightText,
            leftImage: nil, rightImage: nil, rows: TextDiff.rows(left: leftText, right: rightText, options: diffOptions()),
            editable: right == "WORKING", blame: []
        )
        if switchMode { mode = .compare }
        if preferences.showAnnotations { await loadBlame(full: full, wc: wc) }
    }

    func diffOptions() -> TextDiff.Options {
        TextDiff.Options(foldWhitespace: !preferences.showWhitespace, ignoreLineEndings: !preferences.showLineEndings)
    }

    func setCompareRevision(left: Bool, revision: String) async {
        guard var document = compare, let full = absolutePath(document.path) else { return }
        let wc = selectedWorkingCopy
        let text: String
        if revision == "WORKING" {
            text = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
        } else if let wc {
            text = await cat(full, revision: revision, wc: wc)
        } else {
            return
        }
        if left {
            document.leftText = text
            document.leftTitle = revision
        } else {
            document.rightText = text
            document.rightTitle = revision
            document.editable = revision == "WORKING"
        }
        document.rows = TextDiff.rows(left: document.leftText, right: document.rightText, options: diffOptions())
        compare = document
    }

    func compareExternal() {
        guard let document = compare else { return }
        let tool = preferences.compareTool.isEmpty ? "/usr/bin/opendiff" : preferences.compareTool
        let leftURL = FileManager.default.temporaryDirectory.appendingPathComponent("mortar-left-\(document.path)")
        let rightURL = FileManager.default.temporaryDirectory.appendingPathComponent("mortar-right-\(document.path)")
        try? document.leftText.write(to: leftURL, atomically: true, encoding: .utf8)
        try? document.rightText.write(to: rightURL, atomically: true, encoding: .utf8)
        if FileManager.default.isExecutableFile(atPath: tool) {
            Process.launchedProcess(launchPath: tool, arguments: [leftURL.path, rightURL.path])
        }
    }

    func loadBlame(full: String, wc: WCRecord) async {
        guard let output = await invoke(args: ["blame", "--xml", full], repo: repository(for: wc), title: t("action.showAnnotations")), output.code == 0 else { return }
        compare?.blame = SVNXML.blame(output.stdout)
    }

    func discardHunk(at index: Int) {
        guard var document = compare, document.editable else { return }
        let hunks = TextDiff.hunks(document.rows)
        guard hunks.indices.contains(index) else { return }
        let range = hunks[index]
        var rightLines = document.rightText.components(separatedBy: "\n")
        let slice = document.rows[range]
        for row in slice.reversed() {
            if let number = row.rightNumber, number - 1 < rightLines.count, row.kind != .same {
                if row.kind == .insert {
                    rightLines.remove(at: number - 1)
                } else if row.kind == .delete || row.kind == .change {
                    rightLines[number - 1] = row.left
                }
            }
        }
        document.rightText = rightLines.joined(separator: "\n")
        document.rows = TextDiff.rows(left: document.leftText, right: document.rightText, options: diffOptions())
        compare = document
        if let full = absolutePath(document.path) {
            try? document.rightText.write(toFile: full, atomically: true, encoding: .utf8)
        }
    }

    func saveWorkingText(_ text: String) {
        guard var document = compare, document.editable, let full = absolutePath(document.path) else { return }
        document.rightText = text
        document.rows = TextDiff.rows(left: document.leftText, right: text, options: diffOptions())
        compare = document
        try? text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    func showLogChange(_ entry: LogEntry, change: LogPathChange) async {
        guard let repo = selectedRepository else { return }
        let root = repo.url.hasSuffix("/") ? String(repo.url.dropLast()) : repo.url
        let suffix = change.path.hasPrefix("/") ? String(change.path.dropFirst()) : change.path
        let encoded = suffix.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let fileURL = root + "/" + encoded
        let newer = "\(entry.revision)"
        let older = "\(max(entry.revision - 1, 0))"
        let rightOutput = await invoke(args: ["cat", "-r", newer, fileURL], repo: repo, title: t("view.compare"), reportError: false)
        let leftOutput = await invoke(args: ["cat", "-r", older, fileURL], repo: repo, title: t("view.compare"), reportError: false)
        let rightText = change.action == "D" ? "" : (String(data: rightOutput?.stdout ?? Data(), encoding: .utf8) ?? "")
        let leftText = change.action == "A" ? "" : (String(data: leftOutput?.stdout ?? Data(), encoding: .utf8) ?? "")
        if (rightOutput?.code != 0 && change.action != "D") || (leftOutput?.code != 0 && change.action != "A") {
            if AppModel.isAuthenticationFailure((rightOutput?.stderr ?? "") + (leftOutput?.stderr ?? "")) {
                sheet = .password
            } else {
                errorMessage = t("error.svnFailed") + "\n" + (rightOutput?.stderr ?? leftOutput?.stderr ?? "")
            }
            return
        }
        let name = (change.path as NSString).lastPathComponent
        compare = CompareDocument(
            path: name,
            leftTitle: "r\(older)",
            rightTitle: "r\(newer)  \(name)",
            leftText: leftText,
            rightText: rightText,
            leftImage: nil,
            rightImage: nil,
            rows: TextDiff.rows(left: leftText, right: rightText, options: diffOptions()),
            editable: false,
            blame: []
        )
        selectedLogRevision = entry.revision
        mode = .compare
    }

    func loadLog(switchMode: Bool = true) async {
        let target: String
        let repo: RepoRecord?
        if let wc = selectedWorkingCopy {
            let relative = selectedPaths.first ?? browserRoot
            target = absolutePath(relative) ?? wc.path
            repo = repository(for: wc)
        } else if let repository = selectedRepository {
            target = repositoryURL(repository, path: selectedPaths.first ?? browserRoot)
            repo = repository
        } else { return }
        if let cachedRepo = repo, library.session("logcache.off.\(cachedRepo.id)") != "1" {
            logs = library.cachedLogs(repo: cachedRepo.id, path: target)
        }
        guard let output = await invoke(args: ["log", "-v", "--xml", "-l", "200", target], repo: repo, title: t("view.log")), output.code == 0 else { return }
        logs = SVNXML.log(output.stdout)
        if let infoOutput = await invoke(args: ["info", target, "--xml"], repo: repo, title: t("inspector.title"), reportError: false), infoOutput.code == 0 {
            info = SVNXML.info(infoOutput.stdout)
        }
        if let cachedRepo = repo { library.cacheLogs(repo: cachedRepo.id, path: target, entries: logs) }
        if switchMode { mode = .log }
    }

    func updateToRevision(_ revision: Int) async { await update(revision: String(revision), depth: nil, externals: true) }

    func revertToRevision(_ revision: Int) async {
        guard let wc = selectedWorkingCopy else { return }
        let relative = selectedPaths.first ?? ""
        let path = absolutePath(relative) ?? wc.path
        _ = await invoke(args: ["merge", "-r", "HEAD:\(revision)", path], cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("log.revertTo"))
        await refresh()
    }

    func merge(strategy: String, source: String, revisions: [Int], secondURL: String, secondRevision: String, depth: String, ignoreWhitespace: Bool, ignoreEOL: Bool, ignoreAncestry: Bool, recordOnly: Bool, dryRun: Bool) async {
        guard let wc = selectedWorkingCopy else { return }
        var args = ["merge"]
        if dryRun { args.append("--dry-run") }
        if !depth.isEmpty { args.append(contentsOf: ["--depth", depth]) }
        if ignoreWhitespace { args.append("-x") ; args.append("-w") }
        if ignoreEOL { args.append("-x"); args.append("--ignore-eol-style") }
        if ignoreAncestry { args.append("--ignore-ancestry") }
        if recordOnly { args.append("--record-only") }
        switch strategy {
        case "cherry":
            if revisions.isEmpty { return }
            args.append(contentsOf: ["-c", revisions.map(String.init).joined(separator: ",")])
            args.append(source)
        case "advanced":
            args.append("\(source)@\(secondRevision.isEmpty ? "HEAD" : secondRevision)")
            args.append(secondURL)
        case "reintegrate":
            args.append("--reintegrate")
            args.append(source)
        default:
            args.append(source)
        }
        args.append(wc.path)
        _ = await invoke(args: args, cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.merge"))
        if !dryRun { await refresh() }
    }

    func branchOrTag(isTag: Bool, name: String, location: String, revision: String, message: String) async {
        guard let repo = selectedRepository else { return }
        let source = repositoryURL(repo, path: selectedPaths.first ?? browserRoot)
        let destination = location.hasPrefix("http") || location.hasPrefix("file:") || location.hasPrefix("svn")
            ? location.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name
            : repositoryURL(repo, path: location + "/" + name)
        var args = ["copy", source, destination, "-m", message.isEmpty ? (isTag ? "Tag \(name)" : "Branch \(name)") : message]
        if !revision.isEmpty, revision != "HEAD" { args = ["copy", "-r", revision, source, destination, "-m", message] }
        _ = await invoke(args: args, repo: repo, title: isTag ? t("action.tag") : t("action.branch"))
        await refresh()
    }

    func suggestedBranchLocation(tag: Bool) -> String {
        let path = selectedPaths.first ?? browserRoot
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(where: { ["trunk", "branches", "tags"].contains($0) }) else {
            return tag ? "tags" : "branches"
        }
        var copy = parts
        copy[index] = tag ? "tags" : "branches"
        return copy.prefix(index + 1).joined(separator: "/")
    }

    func makeDirectory(_ name: String, message: String) async {
        guard let repo = selectedRepository else { return }
        _ = await invoke(args: ["mkdir", repositoryURL(repo, path: browserRoot.isEmpty ? name : browserRoot + "/" + name), "-m", message], repo: repo, title: t("action.newFolder"))
        await refresh()
    }

    func deleteRemote(message: String) async {
        guard let repo = selectedRepository, revisionSpec == "HEAD" || revisionSpec.isEmpty else { return }
        for path in selectedPaths {
            _ = await invoke(args: ["delete", repositoryURL(repo, path: path), "-m", message], repo: repo, title: t("action.delete"))
        }
        await refresh()
    }

    func setProperty(_ name: String, value: String?, path: String) async {
        guard let wc = selectedWorkingCopy else { return }
        let full = path.hasPrefix("/") ? path : URL(fileURLWithPath: wc.path).appendingPathComponent(path).path
        if let value {
            _ = await invoke(args: ["propset", name, value, full], repo: repository(for: wc), title: t("inspector.save"))
        } else {
            _ = await invoke(args: ["propdel", name, full], repo: repository(for: wc), title: t("inspector.save"))
        }
        await loadInspector(path: full)
    }

    func saveExternals(_ text: String) async {
        guard let relative = selectedPaths.first ?? Optional("") else { return }
        await setProperty("svn:externals", value: text, path: relative.isEmpty ? "" : relative)
    }

    func shelve(name: String, message: String, paths: [String], checkpoint: Bool) async {
        guard let wc = selectedWorkingCopy else { return }
        let full = paths.map { URL(fileURLWithPath: wc.path).appendingPathComponent($0).path }
        guard let output = await invoke(args: ["diff"] + full, cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.shelve")), output.code == 0 else { return }
        let directory = try? LibraryStore.supportDirectory().appendingPathComponent("shelves", isDirectory: true)
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let existing = library.shelves(wc: wc.id).filter { $0.name == name }.map(\.version).max() ?? 0
        let file = (directory ?? FileManager.default.temporaryDirectory).appendingPathComponent("\(wc.id)-\(name)-\(existing + 1).patch")
        try? output.stdout.write(to: file)
        if !checkpoint {
            _ = await invoke(args: ["revert"] + full, cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.revert"))
        }
        library.saveShelf(ShelfRecord(id: UUID().uuidString, workingCopyID: wc.id, name: name, log: message, version: existing + 1, created: Date(), patchPath: file.path, checkpoint: checkpoint))
        await refresh()
    }

    func unshelve(_ shelf: ShelfRecord) async {
        guard let wc = selectedWorkingCopy else { return }
        _ = await invoke(args: ["patch", shelf.patchPath, wc.path], cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("shelve.apply"))
        await refresh()
    }

    func savePatch(to url: URL) async {
        guard let wc = selectedWorkingCopy else { return }
        let paths = selectedPaths.map { URL(fileURLWithPath: wc.path).appendingPathComponent($0).path }
        guard let output = await invoke(args: ["diff"] + paths, cwd: URL(fileURLWithPath: wc.path), repo: repository(for: wc), title: t("action.savePatch")) else { return }
        try? output.stdout.write(to: url)
    }

    func repairRename() async {
        guard let wc = selectedWorkingCopy else { return }
        let added = rows.filter { $0.copied && !$0.movedFrom.isEmpty }
        for row in added where !rows.contains(where: { $0.path == row.movedFrom && $0.item == "deleted" }) {
            let source = URL(fileURLWithPath: wc.path).appendingPathComponent(row.movedFrom).path
            _ = await invoke(args: ["delete", source], repo: repository(for: wc), title: t("action.repair"))
        }
        await refresh()
    }

    func copyURL() {
        let text: String
        if let repo = selectedRepository, selectedWorkingCopy == nil {
            text = repositoryURL(repo, path: selectedPaths.first ?? browserRoot)
        } else if let path = selectedPaths.first, let full = absolutePath(path) {
            text = full
        } else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportLibrary(to url: URL, includeSecrets: Bool, passphrase: String) throws {
        preferences.save()
        try LibraryArchive.exportArchive(database: library.databaseURL, preferences: preferences, includeSecrets: includeSecrets, passphrase: passphrase, to: url)
    }

    func importLibrary(from url: URL, mode: ImportMode, passphrase: String) throws {
        if let prefs = try LibraryArchive.importArchive(at: url, database: library.databaseURL, mode: mode, passphrase: passphrase) {
            preferences = prefs
            language.code = prefs.language
        }
        try library.reopen()
        reloadLists()
        rows = []
        selection = .none
    }

    func runSelfTest() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mortar-self-test-\(UUID().uuidString)", isDirectory: true)
        let result = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MORTAR_SELF_TEST_RESULT"] ?? "/tmp/mortar-self-test.txt")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repoPath = root.appendingPathComponent("repo").path
            await addFileRepository(path: repoPath, nickname: "SelfTest", create: true, compatibility: "1.15", standardLayout: true)
            browserRoot = "trunk"
            await checkout(name: "wc", parent: root, revision: "HEAD", depth: "infinity", externals: true)
            guard let wc = selectedWorkingCopy else { throw SVNClientError.failed("no working copy") }
            let file = URL(fileURLWithPath: wc.path).appendingPathComponent("hello.txt")
            try "hello\n".write(to: file, atomically: true, encoding: .utf8)
            await refresh()
            selectedPaths = ["hello.txt"]
            await addSelected()
            commitItems = [CommitItem(path: "hello.txt", letter: "A", included: true, pairedPath: "")]
            await commit(message: "Add hello", unlock: true, preScript: "", postScript: "")
            try "hello\nworld\n".write(to: file, atomically: true, encoding: .utf8)
            await refresh()
            let changed = rows.first { $0.path == "hello.txt" }
            if changed?.letter != "M" { throw SVNClientError.failed("status was \(changed?.letter ?? "nil")") }
            await compareBase(path: "hello.txt")
            if compare?.rows.contains(where: { $0.kind != .same }) != true { throw SVNClientError.failed("diff empty") }
            await loadLog()
            if logs.isEmpty { throw SVNClientError.failed("log empty") }
            selectedPaths = ["hello.txt"]
            await shelve(name: "wip", message: "checkpoint", paths: ["hello.txt"], checkpoint: true)
            if library.shelves(wc: wc.id).isEmpty { throw SVNClientError.failed("shelf missing") }
            let archive = root.appendingPathComponent("library.mortararchive")
            try exportLibrary(to: archive, includeSecrets: false, passphrase: "")
            try importLibrary(from: archive, mode: .merge, passphrase: "")
            if !FileManager.default.fileExists(atPath: BundledSVN.tool("svn")?.path ?? "") { throw SVNClientError.failed("svn missing") }
            try "OK\n".write(to: result, atomically: true, encoding: .utf8)
        } catch {
            try? "FAIL \(error)\n".write(to: result, atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }

    func acceptTrust() {
        if let repo = selectedRepository { library.trust(repo.url) }
        sheet = nil
    }

    func setProperty(_ name: String, _ value: String) async {
        guard let wc = selectedWorkingCopy, let relative = selectedPaths.first, !name.isEmpty else { return }
        let full = URL(fileURLWithPath: wc.path).appendingPathComponent(relative).path
        _ = await invoke(args: ["propset", name, value, full], repo: repository(for: wc), title: t("inspector.save"))
        await loadInspector(path: full)
    }

    func deleteProperty(_ name: String) async {
        guard let wc = selectedWorkingCopy, let relative = selectedPaths.first else { return }
        let full = URL(fileURLWithPath: wc.path).appendingPathComponent(relative).path
        _ = await invoke(args: ["propdel", name, full], repo: repository(for: wc), title: t("action.delete"))
        await loadInspector(path: full)
    }

    func savePassword(_ password: String, username: String) {
        guard var repo = selectedRepository else { return }
        let name = username.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            repo.username = name
            library.save(repo: repo)
            reloadLists()
        }
        KeychainStore.save(account: keychainAccount(repo, name), secret: password)
        KeychainStore.save(account: repo.id, secret: password)
        sheet = nil
        let reopenLog = mode == .log || mode == .timeline
        Task {
            await refresh()
            if reopenLog { await loadLog() }
        }
    }

    private func ensureRepository(url: String, nickname: String, localPath: String) -> RepoRecord {
        if let existing = repositories.first(where: { $0.url == url }) { return existing }
        let record = RepoRecord(id: UUID().uuidString, nickname: nickname, url: url, localPath: localPath, username: "", inaccessible: false, sortIndex: repositories.count)
        library.save(repo: record)
        reloadLists()
        return record
    }

    private func targetPaths(_ wc: WCRecord) -> [String] {
        if selectedPaths.isEmpty { return [wc.path] }
        return selectedPaths.map { URL(fileURLWithPath: wc.path).appendingPathComponent($0).path }
    }

    private func pair(for row: BrowserRow) -> String {
        if row.copied, !row.movedFrom.isEmpty { return row.movedFrom }
        if row.item == "deleted" {
            return rows.first { $0.movedFrom == row.path }?.path ?? ""
        }
        return ""
    }

    private func propertiesValue(_ name: String, path: String) -> String {
        let processURL = BundledSVN.tool("svn")
        guard let processURL else { return "" }
        let process = Process()
        process.executableURL = processURL
        process.arguments = ["propget", name, path, "--non-interactive"]
        process.environment = BundledSVN.cleanEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func cat(_ path: String, revision: String, wc: WCRecord) async -> String {
        guard let data = await catData(path, revision: revision, wc: wc) else {
            return revision == "WORKING" ? ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "") : ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func catData(_ path: String, revision: String, wc: WCRecord) async -> Data? {
        if revision == "WORKING" { return try? Data(contentsOf: URL(fileURLWithPath: path)) }
        let args = revision == "BASE" ? ["cat", path] : ["cat", "-r", revision, path]
        guard let output = await invoke(args: args, repo: repository(for: wc), title: t("view.compare")), output.code == 0 else { return nil }
        return output.stdout
    }

    private func imageData(_ path: String, revision: String, inline: String) -> Data? {
        guard isImage(path), inline.isEmpty || !inline.utf8.contains(where: { $0 < 9 }) else { return nil }
        return nil
    }

    private func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func conflictFile(_ suffix: String) -> String? {
        guard let url = selectedFileURL() else { return nil }
        let folder = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.contains(suffix) }?.path
    }

    private func runScript(_ path: String, wc: WCRecord, revision: String, paths: [String], message: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = URL(fileURLWithPath: wc.path)
        var env = BundledSVN.cleanEnvironment()
        env["WC_PATH"] = wc.path
        env["REPO_URL"] = repository(for: wc)?.url ?? ""
        env["REVISION"] = revision
        env["LOG_MESSAGE"] = message
        env["PATHS"] = paths.joined(separator: "\n")
        process.environment = env
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
