import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
        SourceListView(model: model)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } detail: {
            detail
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
        }
        .navigationTitle("Mortar")
        .toolbar { toolbarContent }
        .background(ToolbarIconAndLabel())
        .background(WindowFrameMemory(model: model))
        .background(OptionKeyMonitor(held: $model.optionHeld))
        .onChange(of: model.showInspector) { _, shown in
            model.library.setSession("inspector", shown ? "1" : "0")
        }
        .frame(minWidth: 1180, minHeight: 640)
        .alert(model.t("error.svnFailed"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(model.t("action.ok"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.sheet) { sheet in
            SheetRouter(model: model, sheet: sheet)
        }
        .task {
            model.language.code = model.preferences.language
            if ProcessInfo.processInfo.environment["MORTAR_SELF_TEST"] == "1" {
                await model.runSelfTest()
            }
        }
        .onChange(of: model.showIgnored) { _, _ in Task { await model.refresh() } }
        .onChange(of: model.showExternals) { _, _ in Task { await model.refresh() } }
        .onChange(of: model.showRepositoryStatus) { _, _ in Task { await model.refresh() } }
    }

    private var windowTitle: String {
        model.selectedWorkingCopy?.name ?? model.selectedRepository?.nickname ?? "Mortar"
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        leadingTools
        middleTools
        trailingTools
    }

    @ToolbarContentBuilder private var leadingTools: some ToolbarContent {
        tool("toolbar.checkout", "square.and.arrow.down") { model.sheet = .checkout }
        tool("toolbar.newFolder", "folder.badge.plus") { Task { await model.makeDirectory("New Folder", message: "Create folder") } }
        ToolbarSpacer(.fixed)
        tool("toolbar.tag", "tag") { model.sheet = .branch(true) }
        tool("toolbar.branch", "arrow.triangle.branch") { model.sheet = .branch(false) }
        ToolbarSpacer(.fixed)
        tool("toolbar.revert", "arrow.uturn.backward") { Task { await model.revert(paths: []) } }
        tool("toolbar.update", "arrow.triangle.2.circlepath") { Task { await model.update(revision: "HEAD", depth: nil, externals: true) } }
    }

    @ToolbarContentBuilder private var middleTools: some ToolbarContent {
        tool("toolbar.commit", "arrow.up.circle") { model.prepareCommit() }
        tool("toolbar.merge", "arrow.triangle.merge") { model.sheet = .merge }
        ToolbarSpacer(.fixed)
        tool("toolbar.import", "square.and.arrow.down.on.square") { importFiles() }
        tool("toolbar.export", "square.and.arrow.up") { exportFiles() }
        ToolbarSpacer(.fixed)
        tool("toolbar.shelve", "archivebox") { model.sheet = .shelve }
        tool("toolbar.unshelve", "arrow.up.bin") { model.sheet = .unshelve }
    }

    @ToolbarContentBuilder private var trailingTools: some ToolbarContent {
        ToolbarSpacer(.flexible)
        ToolbarItem {
            if model.busy { ProgressView().controlSize(.small) }
        }
        ToolbarItem {
            Menu {
                Toggle(model.t("action.showIgnored"), isOn: $model.showIgnored)
                Toggle(model.t("action.showExternals"), isOn: $model.showExternals)
                Toggle(model.t("action.showRepositoryStatus"), isOn: $model.showRepositoryStatus)
            } label: {
                Label(model.t("toolbar.viewOptions"), systemImage: "eye")
            }
            .help(model.t("toolbar.viewOptions"))
        }
        ToolbarItem {
            Button {
                model.showInspector.toggle()
            } label: {
                Label(model.t("action.showInspector"), systemImage: "sidebar.trailing")
            }
            .help(model.t("action.showInspector"))
        }
    }

    private func tool(_ key: String, _ symbol: String, action: @escaping () -> Void) -> some ToolbarContent {
        ToolbarItem {
            Button(action: action) {
                Label(model.t(key), systemImage: symbol)
            }
            .help(model.t(key))
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            pathBar
            if model.mode == .browser {
                FilterBar(model: model)
            }
            content
        }
        .safeAreaBar(edge: .bottom) { bottomBar }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button { goBack() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    if model.mode != .browser {
                        Text(model.selectedWorkingCopy?.name ?? model.selectedRepository?.nickname ?? model.t("view.browser"))
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.borderless)
            if model.mode == .browser {
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                Text(currentFolderName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            } else {
                Spacer()
                Text(currentFolderName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var currentFolderName: String {
        if model.mode == .log {
            let name = model.selectedWorkingCopy?.name ?? model.selectedRepository?.nickname ?? ""
            return String(format: model.t("log.heading"), name)
        }
        if model.mode == .compare {
            return model.compare?.path ?? model.t("view.compare")
        }
        if model.mode == .timeline { return model.t("view.timeline") }
        if model.mode == .transcript { return model.t("view.transcript") }
        if model.mode == .commit { return model.t("commit.title") }
        if !model.browserRoot.isEmpty { return (model.browserRoot as NSString).lastPathComponent }
        return windowTitle
    }

    private func goBack() {
        if model.mode != .browser {
            model.mode = .browser
        } else {
            model.goBack()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .browser:
            if model.repositories.isEmpty {
                ContentUnavailableView {
                    Text(model.t("action.addRepository"))
                } description: {
                    Text(model.t("empty.browser"))
                } actions: {
                    Button(model.t("action.addRepository")) { model.sheet = .addRepository }
                        .buttonStyle(.borderedProminent)
                    Button(model.t("action.addWorkingCopy")) { model.pickWorkingCopy() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rows.isEmpty {
                ContentUnavailableView(model.t("empty.browser"), systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BrowserOutline(rows: model.rows, root: model.browserRoot, model: model)
            }
        case .compare:
            CompareView(model: model)
        case .log:
            LogView(model: model)
        case .timeline:
            TimelineView(model: model)
        case .transcript:
            TranscriptView(model: model)
        case .commit:
            CommitPane(model: model)
        }
    }

    private var bottomBar: some View {
        Group {
            if model.mode == .compare {
                HStack {
                    Button(model.t("action.compareBase")) { Task { await model.compareBase(path: model.selectedPaths.first) } }
                    Button(model.t("action.compareHead")) { Task { await model.compareHead(path: model.selectedPaths.first) } }
                    Spacer()
                    Text(differenceLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.t("action.ok")) {
                        model.mode = model.selectedLogRevision == nil ? .browser : .log
                    }
                    .keyboardShortcut(.cancelAction)
                }
            } else if model.mode == .log {
                HStack {
                    Button {
                        guard let revision = model.selectedLogRevision else { return }
                        Task { await model.compare(path: model.selectedPaths.first, left: "\(max(revision - 1, 0))", right: "\(revision)") }
                    } label: {
                        Label(model.t("action.showDifferences"), systemImage: "doc.on.doc")
                    }
                    .disabled(model.selectedLogRevision == nil)
                    Spacer()
                    Button {
                        guard let revision = model.selectedLogRevision else { return }
                        Task { await model.revertToRevision(revision) }
                    } label: {
                        Label(model.t("log.revertTo"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.selectedLogRevision == nil)
                    Spacer()
                    Button(model.t("action.ok")) { model.mode = .browser }
                        .keyboardShortcut(.cancelAction)
                }
            } else if model.mode == .timeline {
                HStack {
                    Button {
                        model.openEditor()
                    } label: {
                        Label(model.t("pref.doubleClick.open"), systemImage: "arrow.up.forward.square")
                    }
                    .disabled(model.selectedPaths.isEmpty)
                    Spacer()
                    Button(model.t("action.ok")) { model.mode = .browser }
                        .keyboardShortcut(.cancelAction)
                }
            } else {
                HStack(spacing: 12) {
                    bottom("eye", "action.showAll", "action.showAll", model.mode == .browser) { model.mode = .browser }
                    bottom("arrow.up.forward.square", "bottom.open", "pref.doubleClick.open", false) { model.openEditor() }
                    bottom("plus", "action.add", "action.add", false) { Task { await model.addSelected() } }
                    bottom("checkmark.circle", "bottom.resolve", "action.resolve", false) { model.sheet = .resolve }
                    Spacer(minLength: 24)
                    bottom("book", "view.log", "view.log", model.mode == .log) { Task { await model.loadLog() } }
                    bottom("point.3.connected.trianglepath.dotted", "view.timeline", "view.timeline", model.mode == .timeline) {
                        model.mode = .timeline
                        if model.logs.isEmpty { Task { await model.loadLog(switchMode: false) } }
                    }
                    bottom("text.alignleft", "view.transcript", "view.transcript", model.mode == .transcript) {
                        model.mode = .transcript
                        Task { await model.refresh() }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private var differenceLabel: String {
        let count = TextDiff.hunks(model.compare?.rows ?? []).count
        return "\(count)"
    }

    private func bottom(_ symbol: String, _ key: String, _ help: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(height: 16)
                Text(model.t(key))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(minWidth: 64)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help(model.t(help))
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            Task { await model.importItems(panel.urls, includeChildren: true, useIgnores: true, message: "Import", rename: "") }
        }
    }

    private func exportFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.exportSelection(to: url) }
        }
    }
}

private struct WindowFrameMemory: NSViewRepresentable {
    var model: AppModel
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if !context.coordinator.restored, let raw = model.library.session("window.frame") {
                let parts = raw.split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 {
                    window.setFrame(NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]), display: false)
                }
                context.coordinator.restored = true
                NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
                    save(window)
                }
                NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                    save(window)
                }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    private func save(_ window: NSWindow) {
        let frame = window.frame
        model.library.setSession("window.frame", "\(frame.origin.x),\(frame.origin.y),\(frame.size.width),\(frame.size.height)")
    }
    final class Coordinator { var restored = false }
}

private struct OptionKeyMonitor: NSViewRepresentable {
    @Binding var held: Bool
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak view] event in
            let down = event.modifierFlags.contains(.option)
            DispatchQueue.main.async { view?.window.map { _ in self.held = down } }
            return event
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var monitor: Any? }
}

private struct ToolbarIconAndLabel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.toolbar?.displayMode = .iconAndLabel
        }
    }
}

struct FilterBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    if model.selectedWorkingCopy == nil, model.selectedRepository != nil {
                        TextField(model.t("field.revision"), text: $model.revisionSpec)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 88)
                            .onSubmit { Task { await model.refresh() } }
                    }
                    ForEach(filters, id: \.0) { key, title in
                        let selected = key == "locked" ? (model.filter == "locked" || model.filterLocked) : model.filter == key
                        Button(model.t(title)) {
                            if key == "locked", model.filter != "all", model.filter != "locked" {
                                model.filterLocked.toggle()
                            } else {
                                model.filter = key
                                if key != "locked" { model.filterLocked = false }
                            }
                        }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(selected ? .regular.interactive() : .clear.interactive(), in: Capsule())
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }
                }
            }
            }
            .frame(height: 28)
            TextField(model.t("filter.search"), text: $model.search, prompt: Text(model.t("filter.search")))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            Group {
                Button("") { model.filter = "all"; model.filterLocked = false }.keyboardShortcut("a", modifiers: .control)
                Button("") { model.filter = "changed" }.keyboardShortcut("c", modifiers: .control)
                Button("") { model.filter = "modified" }.keyboardShortcut("o", modifiers: .control)
                Button("") { model.filter = "conflicted" }.keyboardShortcut("f", modifiers: .control)
                Button("") { model.filter = "missing" }.keyboardShortcut("g", modifiers: .control)
                Button("") { model.filter = "unversioned" }.keyboardShortcut("u", modifiers: .control)
                Button("") { model.filter = "switched" }.keyboardShortcut("s", modifiers: .control)
                Button("") { model.filter = "locked"; model.filterLocked = false }.keyboardShortcut("l", modifiers: .control)
                Button("") { model.filter = "newer" }.keyboardShortcut("n", modifiers: .control)
                Button("") { model.filter = "today" }.keyboardShortcut("t", modifiers: .control)
                Button("") { model.filter = "week" }.keyboardShortcut("w", modifiers: .control)
                Button("") { model.filter = "month" }.keyboardShortcut("m", modifiers: .control)
                Button("") { model.filter = "recent" }.keyboardShortcut("r", modifiers: .control)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var filters: [(String, String)] {
        if model.selectedWorkingCopy != nil {
            var items = [("all", "filter.all"), ("changed", "filter.changed"), ("modified", "filter.modified"), ("conflicted", "filter.conflicted"), ("missing", "filter.missing"), ("unversioned", "filter.unversioned"), ("switched", "filter.switched"), ("locked", "filter.locked")]
            if model.showRepositoryStatus { items.append(("newer", "filter.newer")) }
            return items
        }
        return [("all", "filter.all"), ("recent", "filter.mostRecent"), ("today", "filter.today"), ("week", "filter.thisWeek"), ("month", "filter.thisMonth"), ("locked", "filter.locked")]
    }
}

private final class SidebarFrameFixingView: NSView {
    private var fixing = false

    override func layout() {
        super.layout()
        guard !fixing else { return }
        fixing = true
        realign()
        fixing = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    private func realign() {
        guard let content = window?.contentView else { return }
        var node: NSView? = self
        while let current = node {
            guard let parent = current.superview else { break }
            let parentFrame = parent.convert(parent.bounds, to: nil)
            let parentAligned = abs(parentFrame.minX) < 1 && abs(parentFrame.width - content.bounds.width) < 2
            if parentAligned {
                let frame = current.convert(current.bounds, to: nil)
                let left = -frame.minX
                let right = frame.maxX - content.bounds.width
                if left > 1 || right > 1 {
                    var fixed = current.frame
                    fixed.origin.x += max(0, left)
                    fixed.size.width -= max(0, left) + max(0, right)
                    if fixed.width > 100, fixed != current.frame {
                        current.frame = fixed
                    }
                }
                return
            }
            node = parent
        }
    }
}

private struct SidebarFrameProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SidebarFrameFixingView() }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.needsLayout = true }
}

struct SourceListView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.repositories) { repo in
                    sourceRow(selected: model.selection == .repository(repo.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Label(repo.nickname, systemImage: "externaldrive.connected.to.line.below")
                                .lineLimit(1)
                            Text(subtitle(repo))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } action: {
                        model.select(.repository(repo.id))
                    }
                    .contextMenu { repositoryMenu(repo) }

                    ForEach(model.workingCopies.filter { $0.repositoryID == repo.id }) { wc in
                        sourceRow(selected: model.selection == .workingCopy(wc.id)) {
                            HStack(spacing: 6) {
                                Label {
                                    Text(wc.name).lineLimit(1)
                                } icon: {
                                    Image(systemName: wc.inaccessible ? "exclamationmark.triangle" : "folder")
                                }
                                .foregroundStyle(wc.inaccessible ? .secondary : .primary)
                                Spacer(minLength: 4)
                                if wc.localChanges > 0 {
                                    Text(model.formattedCount(wc.localChanges))
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.primary, in: Capsule())
                                        .foregroundStyle(.background)
                                }
                                if wc.pendingUpdates > 0 {
                                    Text(model.formattedCount(wc.pendingUpdates))
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .overlay { Capsule().stroke(.secondary) }
                                }
                            }
                            .padding(.leading, 12)
                        } action: {
                            model.select(.workingCopy(wc.id))
                        }
                        .contextMenu { workingCopyMenu(wc) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? URL {
                            urls.append(url)
                        } else if let data = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                                  let string = String(data: data, encoding: .utf8),
                                  let url = URL(string: string) {
                            urls.append(url)
                        }
                    }
                    model.receiveExternalDrop(urls)
                }
                return true
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(SidebarFrameProbe())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Menu {
                    Button(model.t("action.addRepository")) { model.sheet = .addRepository }
                    Button(model.t("action.addWorkingCopy")) { model.pickWorkingCopy() }
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceRow<Content: View>(selected: Bool, @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ repo: RepoRecord) -> String {
        if let url = URL(string: repo.url), let host = url.host {
            let path = url.path == "/" ? "" : url.path
            return path.isEmpty ? host : "\(host)\(path)"
        }
        return repo.url
    }

    @ViewBuilder private func workingCopyMenu(_ wc: WCRecord) -> some View {
        Button(model.t("action.update")) { Task { await model.update(revision: "HEAD", depth: nil, externals: true) } }
        Button(model.t("action.commit")) { model.prepareCommit() }
        Button(model.t("action.cleanup")) { Task { await model.cleanup() } }
        Button(model.t("action.switch")) { model.sheet = .switchURL }
        Button(model.t("action.relocate")) { model.sheet = .relocate }
        Button(model.t("action.upgrade")) { Task { await model.upgradeWorkingCopy() } }
        Button(model.t("action.merge")) { model.sheet = .merge }
        Button(model.t("action.shelve")) { model.sheet = .shelve }
        Button(model.t("shelve.apply")) { model.sheet = .unshelve }
        Divider()
        Button(model.t("action.removeFromList")) { model.removeSelection() }
    }

    @ViewBuilder private func repositoryMenu(_ repo: RepoRecord) -> some View {
        Button(model.t("action.copyURL")) { model.copyURL() }
        Button(model.t("action.issues")) { model.sheet = .issues }
        Button(model.library.session("logcache.off.\(repo.id)") == "1" ? model.t("filter.all") : model.t("log.cacheClear")) {
            let key = "logcache.off.\(repo.id)"
            model.library.setSession(key, model.library.session(key) == "1" ? "0" : "1")
        }
        Button("\(model.t("log.cacheClear")) (\(model.library.logCacheCount(repo: repo.id)))") {
            model.library.clearLogCache(repo: repo.id)
        }
        Button(model.t("action.removeFromList")) { model.removeSelection() }
    }
}
