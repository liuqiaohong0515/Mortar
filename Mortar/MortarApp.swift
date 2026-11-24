import SwiftUI

@main
struct MortarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainWindow(model: model)
        }
        .windowToolbarStyle(.unified)
        .commands { MortarCommands(model: model) }
        Settings {
            PreferencesView(model: model)
        }
    }
}

struct MortarCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.t("action.addRepository")) { model.sheet = .addRepository }.keyboardShortcut("n", modifiers: [.command, .option])
            Button(model.t("action.addWorkingCopy")) { model.sheet = .addWorkingCopy }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button(model.t("action.checkout")) { model.sheet = .checkout }.keyboardShortcut("o", modifiers: [.command, .option])
            Button(model.t("action.import")) { importFiles() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button(model.t("action.export")) { exportFiles() }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button(model.t("action.download")) { Task { await model.downloadSelection() } }
            Divider()
            Button(model.t("archive.export")) { model.sheet = .exportLibrary }
            Button(model.t("archive.import")) { model.sheet = .importLibrary }
            Divider()
            Button(model.t("action.openExternals")) { model.sheet = .externals }.keyboardShortcut("x", modifiers: [.command, .shift])
            Button(model.t("action.revealFinder")) { model.revealFinder() }
            Button(model.t("action.openTerminal")) { model.openTerminal() }.keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appInfo) {
            Button(model.t("action.about")) { model.sheet = .about }
        }
        CommandMenu(model.t("menu.view")) {
            Button(model.t("view.browser")) { model.mode = .browser }.keyboardShortcut("1", modifiers: .command)
            Button(model.t("view.compare")) { model.mode = .compare }.keyboardShortcut("2", modifiers: .command)
            Button(model.t("view.log")) { Task { await model.loadLog() } }.keyboardShortcut("3", modifiers: .command)
            Button(model.t("view.timeline")) { model.mode = .timeline }.keyboardShortcut("4", modifiers: .command)
            Button(model.t("view.transcript")) { model.mode = .transcript }.keyboardShortcut("5", modifiers: .command)
            Divider()
            Button(model.t("action.refresh")) { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: .command)
            Button(model.t("action.showAll")) { model.filter = "all"; model.search = "" }.keyboardShortcut("\\", modifiers: .command)
            Button(model.t("action.showIgnored")) { model.showIgnored.toggle(); Task { await model.refresh() } }
            Button(model.t("action.showExternals")) { model.showExternals.toggle(); Task { await model.refresh() } }
            Button(model.t("action.showRepositoryStatus")) { model.showRepositoryStatus.toggle(); Task { await model.refresh() } }
            Button(model.t("action.showInspector")) { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: .command)
        }
        CommandMenu(model.t("menu.workingCopy")) {
            Button(model.t("action.updateToLatest")) { Task { await model.update(revision: "HEAD", depth: nil, externals: true) } }.keyboardShortcut("u", modifiers: .command)
            Button(model.t("action.update")) { model.sheet = .update }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button(model.t("action.commit")) { model.prepareCommit() }.keyboardShortcut("t", modifiers: .command)
            Button(model.t("action.commitAll")) {
                model.selectedPaths = []
                model.prepareCommit()
            }.keyboardShortcut("t", modifiers: [.command, .option])
            Button(model.t("action.revert")) { Task { await model.revert(paths: []) } }.keyboardShortcut(.delete, modifiers: .command)
            Button(model.t("action.resolve")) { model.sheet = .resolve }.keyboardShortcut("k", modifiers: .command)
            Button(model.t("action.add")) { Task { await model.addSelected() } }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button(model.t("action.delete")) { Task { await model.deleteSelected(trash: true) } }.keyboardShortcut(.delete, modifiers: [.command, .option])
            Button(model.t("action.ignore")) { Task { await model.ignoreSelected() } }
            Button(model.t("action.cleanup")) { Task { await model.cleanup() } }
            Button(model.t("action.merge")) { model.sheet = .merge }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button(model.t("action.shelve")) { model.sheet = .shelve }
            Button(model.t("shelve.apply")) { model.sheet = .unshelve }
            Button(model.t("action.compareBase")) { Task { await model.compareBase() } }.keyboardShortcut(.return, modifiers: .command)
            Button(model.t("action.compareHead")) { Task { await model.compareHead() } }.keyboardShortcut(.return, modifiers: [.command, .shift])
        }
        CommandMenu(model.t("menu.repository")) {
            Button(model.t("action.newFolder")) { Task { await model.makeDirectory("folder", message: "Create folder") } }
            Button(model.t("action.tag")) { model.sheet = .branch(true) }
            Button(model.t("action.branch")) { model.sheet = .branch(false) }
            Button(model.t("action.copyURL")) { model.copyURL() }
            Button(model.t("action.issues")) { model.sheet = .issues }
        }
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
