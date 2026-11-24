import SwiftUI
import UniformTypeIdentifiers

struct SheetRouter: View {
    @Bindable var model: AppModel
    var sheet: WorkspaceSheet

    var body: some View {
        switch sheet {
        case .addRepository: AddRepositorySheet(model: model)
        case .addWorkingCopy: FolderSheet(model: model, title: model.t("action.addWorkingCopy")) { url in Task { await model.addWorkingCopy(at: url) } }
        case .checkout: CheckoutSheet(model: model)
        case .commit: CommitSheet(model: model)
        case .update: UpdateSheet(model: model)
        case .merge: MergeSheet(model: model)
        case .branch(let tag): BranchSheet(model: model, tag: tag)
        case .relocate: TextPrompt(title: model.t("action.relocate"), label: model.t("field.url"), cancelTitle: model.t("action.cancel"), confirmTitle: model.t("action.ok")) { value in Task { await model.relocate(to: value); model.sheet = nil } }
        case .switchURL: TextPrompt(title: model.t("action.switch"), label: model.t("field.url"), cancelTitle: model.t("action.cancel"), confirmTitle: model.t("action.ok")) { value in Task { await model.switchURL(value, revision: "HEAD"); model.sheet = nil } }
        case .externals: ExternalsSheet(model: model)
        case .issues: IssuesSheet(model: model)
        case .shelve: ShelveSheet(model: model)
        case .unshelve: UnshelveSheet(model: model)
        case .exportLibrary: ExportSheet(model: model)
        case .importLibrary: ImportSheet(model: model)
        case .about: AboutSheet(model: model)
        case .resolve: ResolveSheet(model: model)
        case .trust(let message): TrustSheet(model: model, message: message)
        case .password: PasswordSheet(model: model)
        case .repair: RepairSheet(model: model)
        case .note(let id): NoteSheet(model: model, id: id)
        case .networkVolume(let path):
            VStack(alignment: .leading, spacing: 12) {
                Text(model.t("network.warning"))
                HStack {
                    Button(model.t("action.cancel")) { model.sheet = nil }
                    Spacer()
                    Button(model.t("action.ok")) {
                        model.sheet = nil
                        Task { await model.addWorkingCopy(at: URL(fileURLWithPath: path), forceNetwork: true) }
                    }
                }
            }
            .padding(20)
            .frame(width: 420)
        case .help:
            VStack(alignment: .leading, spacing: 8) {
                Text(model.t("menu.help")).font(.title3)
                Text(model.t("timeline.prompt"))
                Button(model.t("action.ok")) { model.sheet = nil }
            }
            .padding(20)
            .frame(width: 420)
        }
    }
}

struct AddRepositorySheet: View {
    @Bindable var model: AppModel
    @State private var kind = "file"
    @State private var create = false
    @State private var path = ""
    @State private var nickname = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var savePassword = true
    @State private var standard = true
    @State private var cloud = "assembla"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("action.addRepository")).font(.title3)
            Picker("", selection: $kind) {
                Text(model.t("repo.file")).tag("file")
                Text(model.t("repo.http")).tag("http")
                Text(model.t("repo.svn")).tag("svn")
                Text(model.t("repo.cloud")).tag("cloud")
            }.pickerStyle(.segmented)
            TextField(model.t("field.nickname"), text: $nickname)
            if kind == "file" {
                Toggle(model.t("repo.createNew"), isOn: $create)
                TextField(model.t("field.path"), text: $path)
                Toggle(model.t("repo.standardLayout"), isOn: $standard).disabled(!create)
            } else if kind == "cloud" {
                Picker(model.t("repo.cloud"), selection: $cloud) {
                    Text("Assembla").tag("assembla")
                    Text("Beanstalk").tag("beanstalk")
                    Text("CloudForge").tag("cloudforge")
                    Text("Codesion").tag("codesion")
                }
                TextField(model.t("field.url"), text: $url)
                TextField(model.t("field.username"), text: $username)
                SecureField(model.t("field.password"), text: $password)
            } else {
                TextField(model.t("field.url"), text: $url)
                TextField(model.t("field.username"), text: $username)
                SecureField(model.t("field.password"), text: $password)
                Toggle(model.t("field.savePassword"), isOn: $savePassword)
            }
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("action.addRepository")) { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submit() {
        Task {
            if kind == "file" {
                await model.addFileRepository(path: path, nickname: nickname, create: create, compatibility: "1.14", standardLayout: standard)
            } else {
                var remote = url
                if kind == "cloud", !url.contains("://") {
                    switch cloud {
                    case "assembla": remote = "svn+ssh://\(username)@subversion.assembla.com/\(url)"
                    case "beanstalk": remote = "https://\(username).svn.beanstalkapp.com/\(url)"
                    case "cloudforge": remote = "https://\(username).svn.cloudforge.com/\(url)"
                    default: remote = "https://\(username).svn.codesion.com/\(url)"
                    }
                }
                model.addRemoteRepository(url: remote, nickname: nickname, username: username, password: password, savePassword: savePassword)
            }
            dismiss()
        }
    }
}

struct CheckoutSheet: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var revision = "HEAD"
    @State private var depth = "infinity"
    @State private var externals = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t("checkout.title")).font(.title3)
            TextField(model.t("checkout.saveAs"), text: $name)
            TextField(model.t("field.path"), text: $parent)
            TextField(model.t("field.revision"), text: $revision)
            Picker(model.t("field.depth"), selection: $depth) {
                Text(model.t("depth.infinity")).tag("infinity")
                Text(model.t("depth.immediates")).tag("immediates")
                Text(model.t("depth.files")).tag("files")
                Text(model.t("depth.empty")).tag("empty")
            }
            Toggle(model.t("field.includeExternals"), isOn: $externals)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("action.checkout")) {
                    Task { await model.checkout(name: name, parent: URL(fileURLWithPath: parent), revision: revision, depth: depth, externals: externals); dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 480)
    }
}

struct CommitSheet: View {
    @Bindable var model: AppModel
    @State private var message = ""
    @State private var unlock = true
    @State private var postScript = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading) {
                Text(model.t("commit.title")).font(.title3)
                TextEditor(text: $message).font(.system(size: model.preferences.commitLogFontSize, design: .monospaced)).frame(minHeight: 160)
                if !model.logs.isEmpty {
                    Menu(model.t("log.copy")) {
                        ForEach(model.logs.prefix(6)) { entry in
                            Button(entry.message.isEmpty ? "r\(entry.revision)" : entry.message) { message = entry.message }
                        }
                    }
                }
                TextField(model.t("commit.postScript"), text: $postScript)
                Toggle(model.t("commit.unlock"), isOn: $unlock)
                HStack {
                    Button(model.t("action.cancel")) { model.logDraft = message; dismiss() }
                    Spacer()
                    Button(model.t("commit.button")) {
                        Task { await model.commit(message: message, unlock: unlock, preScript: model.preferences.preCommitScript, postScript: postScript) }
                    }.keyboardShortcut(.defaultAction)
                }
            }.frame(minWidth: 280)
            List {
                ForEach($model.commitItems) { $item in
                    Toggle(isOn: $item.included) { Text("\(item.letter)  \(item.path)").font(.system(.body, design: .monospaced)) }
                }
            }.frame(minWidth: 320, minHeight: 280)
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { message = model.logDraft }
    }
}

struct UpdateSheet: View {
    @Bindable var model: AppModel
    @State private var revision = "HEAD"
    @State private var depth = ""
    @State private var externals = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text(model.t("action.update")).font(.title3)
            TextField(model.t("field.revision"), text: $revision)
            TextField(model.t("column.depth"), text: $depth)
            Toggle(model.t("field.includeExternals"), isOn: $externals)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("action.update")) { Task { await model.update(revision: revision, depth: depth.isEmpty ? nil : depth, externals: externals); dismiss() } }
            }
        }.padding(20).frame(width: 420)
    }
}

struct MergeSheet: View {
    @Bindable var model: AppModel
    @State private var strategy = "sync"
    @State private var source = ""
    @State private var revisions = ""
    @State private var second = ""
    @State private var ignoreWhitespace = false
    @State private var ignoreAncestry = false
    @State private var recordOnly = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("action.merge")).font(.title3)
            Picker("", selection: $strategy) {
                Text(model.t("merge.sync")).tag("sync")
                Text(model.t("merge.reintegrate")).tag("reintegrate")
                Text(model.t("merge.cherry")).tag("cherry")
                Text(model.t("merge.advanced")).tag("advanced")
            }.pickerStyle(.segmented)
            TextField(model.t("merge.source"), text: $source)
            if strategy == "cherry" { TextField(model.t("field.revision"), text: $revisions) }
            if strategy == "advanced" { TextField(model.t("field.url"), text: $second) }
            Toggle(model.t("merge.ignoreWhitespace"), isOn: $ignoreWhitespace)
            Toggle(model.t("merge.ignoreAncestry"), isOn: $ignoreAncestry).disabled(strategy == "reintegrate")
            Toggle(model.t("merge.recordOnly"), isOn: $recordOnly)
            if model.rows.contains(where: { !$0.letter.isEmpty && $0.letter != "X" && $0.letter != "I" }) {
                Text(model.t("merge.localChanges")).foregroundStyle(.orange).font(.caption)
            }
            HStack {
                Button(model.t("merge.dryRun")) { run(dry: true) }
                Spacer()
                Button(model.t("action.cancel")) { dismiss() }
                Button(model.t("merge.button")) { run(dry: false) }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 520)
    }

    private func run(dry: Bool) {
        let revs = revisions.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        Task {
            await model.merge(strategy: strategy, source: source, revisions: revs, secondURL: second, secondRevision: "HEAD", depth: "infinity", ignoreWhitespace: ignoreWhitespace, ignoreEOL: false, ignoreAncestry: ignoreAncestry, recordOnly: recordOnly, dryRun: dry)
            if !dry { dismiss() }
        }
    }
}

struct BranchSheet: View {
    @Bindable var model: AppModel
    var tag: Bool
    @State private var name = ""
    @State private var location = ""
    @State private var revision = "HEAD"
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text(tag ? model.t("action.tag") : model.t("action.branch")).font(.title3)
            TextField(model.t("field.name"), text: $name)
            TextField(model.t("field.where"), text: $location)
            TextField(model.t("field.revision"), text: $revision)
            TextField(model.t("field.message"), text: $message)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("action.create")) {
                    Task { await model.branchOrTag(isTag: tag, name: name, location: location, revision: revision, message: message); dismiss() }
                }
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { location = model.suggestedBranchLocation(tag: tag) }
    }
}

struct ShelveSheet: View {
    @Bindable var model: AppModel
    @State private var checkpoint = false
    @State private var name = ""
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Picker("", selection: $checkpoint) {
                Text(model.t("shelve.shelf")).tag(false)
                Text(model.t("shelve.checkpoint")).tag(true)
            }.pickerStyle(.segmented)
            TextField(model.t("field.name"), text: $name)
            TextField(model.t("field.message"), text: $message, axis: .vertical)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("action.shelve")) {
                    let paths = model.selectedPaths.isEmpty ? model.rows.filter(\.isChangedWait).map(\.path) : model.selectedPaths
                    Task { await model.shelve(name: name, message: message, paths: paths, checkpoint: checkpoint); dismiss() }
                }
            }
        }.padding(20).frame(width: 460)
    }
}

struct UnshelveSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shelves = model.selectedWorkingCopy.map { model.library.shelves(wc: $0.id) } ?? []
        VStack(alignment: .leading) {
            Text(model.t("shelve.apply")).font(.title3)
            List(shelves) { shelf in
                Button("\(shelf.name)  v\(shelf.version)  \(shelf.checkpoint ? model.t("shelve.checkpoint") : model.t("shelve.shelf"))") {
                    Task { await model.unshelve(shelf); dismiss() }
                }
            }.frame(height: 220)
            Button(model.t("action.cancel")) { dismiss() }
        }.padding(20).frame(width: 460)
    }
}

struct ExportSheet: View {
    @Bindable var model: AppModel
    @State private var include = false
    @State private var passphrase = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text(model.t("archive.export")).font(.title3)
            Toggle(model.t("archive.includePasswords"), isOn: $include)
            SecureField(model.t("archive.passphrase"), text: $passphrase).disabled(!include)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("action.export")) { save() }
            }
        }.padding(20).frame(width: 440)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mortararchive") ?? .data]
        panel.nameFieldStringValue = "Mortar.mortararchive"
        if panel.runModal() == .OK, let url = panel.url {
            try? model.exportLibrary(to: url, includeSecrets: include, passphrase: passphrase)
            dismiss()
        }
    }
}

struct ImportSheet: View {
    @Bindable var model: AppModel
    @State private var passphrase = ""
    @State private var replace = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text(model.t("archive.import")).font(.title3)
            Picker("", selection: $replace) {
                Text(model.t("archive.replace")).tag(true)
                Text(model.t("archive.merge")).tag(false)
            }
            SecureField(model.t("archive.passphrase"), text: $passphrase)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("action.importLibrary")) { open() }
            }
        }.padding(20).frame(width: 440)
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mortararchive") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try model.importLibrary(from: url, mode: replace ? .replace : .merge, passphrase: passphrase)
                dismiss()
            } catch {
                model.errorMessage = model.t("archive.badPassphrase")
            }
        }
    }
}

struct AboutSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 8) {
            Text("Mortar").font(.title)
            Text(model.t("about.version") + " 1.0")
            Text(model.t("about.svn") + " " + BundledSVN.version).font(.system(.body, design: .monospaced))
            Button(model.t("action.ok")) { dismiss() }
        }.padding(24).frame(width: 320)
    }
}

struct TrustSheet: View {
    var model: AppModel
    var message: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text(model.t("trust.title")).font(.title3)
            Text(message).font(.system(.caption, design: .monospaced)).frame(maxHeight: 180)
            HStack {
                Button(model.t("trust.reject")) { dismiss() }
                Spacer()
                Button(model.t("trust.always")) { model.acceptTrust(); dismiss() }
            }
        }.padding(20).frame(width: 520)
    }
}

struct PasswordSheet: View {
    @Bindable var model: AppModel
    @State private var username = ""
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t("field.password")).font(.title3)
            Text(model.t("password.explain"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = model.selectedRepository?.url, !url.isEmpty {
                Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            TextField(model.t("field.username"), text: $username)
            SecureField(model.t("field.password"), text: $password)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("action.save")) { model.savePassword(password, username: username); dismiss() }
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { username = model.suggestedUsername() }
    }
}

struct ResolveSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text(model.t("action.resolve")).font(.title3)
            Text(model.t("log.modified")).font(.caption).foregroundStyle(.secondary)
            Button(model.t("action.resolveMine")) { Task { await model.resolve(accept: "mine-full"); dismiss() } }
            Button(model.t("action.resolveTheirs")) { Task { await model.resolve(accept: "theirs-full"); dismiss() } }
            Text(model.t("column.props")).font(.caption).foregroundStyle(.secondary)
            Button(model.t("action.resolveMine")) { Task { await model.resolve(accept: "mine-conflict"); dismiss() } }
            Button(model.t("action.resolveTheirs")) { Task { await model.resolve(accept: "theirs-conflict"); dismiss() } }
            Text(model.t("column.kind")).font(.caption).foregroundStyle(.secondary)
            Button(model.t("action.resolveWorking")) { Task { await model.resolve(accept: "working"); dismiss() } }
            Button(model.t("action.resolveBase")) { Task { await model.resolve(accept: "base"); dismiss() } }
            Button(model.t("action.resolveWorking")) { Task { await model.resolve(accept: "working"); dismiss() } }
            Button(model.t("action.resolveTool")) { model.resolveWithTool() }
            Button(model.t("action.cancel")) { dismiss() }
        }.padding(20).frame(width: 360)
    }
}

struct ExternalsSheet: View {
    @Bindable var model: AppModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text(model.t("inspector.externals")).font(.title3)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 200)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("inspector.save")) { Task { await model.saveExternals(text); dismiss() } }
            }
        }.padding(20).frame(width: 560)
        .onAppear { text = model.properties.first { $0.name == "svn:externals" }?.value ?? "" }
    }
}

struct IssuesSheet: View {
    @Bindable var model: AppModel
    @State private var pattern = "#(\\d+)"
    @State private var template = "https://example.com/issues/{number}"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text(model.t("action.issues")).font(.title3)
            TextField(model.t("field.name"), text: $pattern)
            TextField(model.t("field.url"), text: $template)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Spacer()
                Button(model.t("action.save")) {
                    if let repo = model.selectedRepository {
                        model.library.saveIssueRules(repo: repo.id, rules: [IssueRule(id: UUID().uuidString, pattern: pattern, urlTemplate: template)])
                    }
                    dismiss()
                }
            }
        }.padding(20).frame(width: 480)
    }
}

struct RepairSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            Text(model.t("action.repair"))
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Button(model.t("action.repair")) { Task { await model.repairRename(); dismiss() } }
            }
        }.padding(20)
    }
}

struct NoteSheet: View {
    var model: AppModel
    var id: String
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            TextField(model.t("transcript.note"), text: $note)
            HStack {
                Button(model.t("action.cancel")) { dismiss() }
                Button(model.t("action.save")) { model.library.setNote(id: id, note: note); Task { await model.refresh() }; dismiss() }
            }
        }.padding(20).frame(width: 400)
    }
}

struct TextPrompt: View {
    var title: String
    var label: String
    var cancelTitle: String
    var confirmTitle: String
    var onSubmit: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.title3)
            TextField(label, text: $text)
            HStack {
                Button(cancelTitle) { dismiss() }
                Spacer()
                Button(confirmTitle) { onSubmit(text); dismiss() }
            }
        }.padding(20).frame(width: 440)
    }
}

struct FolderSheet: View {
    var model: AppModel
    var title: String
    var onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            Text(title)
            Button(model.t("action.browse")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { onPick(url); dismiss() }
            }
            Button(model.t("action.cancel")) { dismiss() }
        }.padding(20)
    }
}

private extension BrowserRow {
    var isChangedWait: Bool { letter == "M" || letter == "A" || letter == "D" || letter == "?" }
}
