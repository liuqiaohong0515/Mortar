import SwiftUI

struct PreferencesView: View {
    @Bindable var model: AppModel
    @State private var prefs: Preferences

    init(model: AppModel) {
        self.model = model
        _prefs = State(initialValue: model.preferences)
    }

    var body: some View {
        TabView {
            general.tabItem { Text(model.t("pref.general")) }
            working.tabItem { Text(model.t("pref.workingCopies")) }
            security.tabItem { Text(model.t("pref.security")) }
            locations.tabItem { Text(model.t("pref.locations")) }
            notes.tabItem { Text(model.t("pref.notifications")) }
            properties.tabItem { Text(model.t("pref.userProperties")) }
        }
        .padding(16)
        .frame(width: 640, height: 460)
        .onChange(of: prefs) { _, newValue in
            model.preferences = newValue
            newValue.save()
            model.language.code = newValue.language
        }
    }

    private var general: some View {
        Form {
            Picker(model.t("pref.language"), selection: $prefs.language) {
                Text(model.t("pref.followSystem")).tag("")
                ForEach(LanguageController.supported, id: \.self) { code in
                    Text(code).tag(code)
                }
            }
            Picker(model.t("pref.doubleClick"), selection: $prefs.doubleClick) {
                Text(model.t("pref.doubleClick.open")).tag("open")
                Text(model.t("pref.doubleClick.compare")).tag("compare")
                Text(model.t("pref.doubleClick.quickLook")).tag("quickLook")
            }
            TextField(model.t("pref.font"), text: $prefs.fontName)
            Stepper(model.t("pref.tabWidth") + " \(prefs.tabWidth)", value: $prefs.tabWidth, in: 1...8)
            TextField(model.t("pref.compareTool"), text: $prefs.compareTool)
            TextField(model.t("pref.mergeTool"), text: $prefs.mergeTool)
            Toggle(model.t("compare.inline"), isOn: $prefs.showInline)
            Toggle(model.t("compare.lineNumbers"), isOn: $prefs.showLineNumbers)
            Toggle(model.t("compare.whitespace"), isOn: $prefs.showWhitespace)
            Toggle(model.t("compare.invisibles"), isOn: $prefs.showInvisibles)
            Toggle(model.t("action.showAnnotations"), isOn: $prefs.showAnnotations)
        }
    }

    private var working: some View {
        Form {
            TextField(model.t("pref.globalIgnores"), text: $prefs.globalIgnores, axis: .vertical)
            Toggle(model.t("pref.autoProps"), isOn: $prefs.autoProps)
            Toggle(model.t("pref.useCommitTimes"), isOn: $prefs.useCommitTimes)
            Toggle(model.t("pref.showTranscriptOnUpdate"), isOn: $prefs.showTranscriptOnUpdate)
            Toggle(model.t("pref.allowExternalHEAD"), isOn: $prefs.allowExternalHEAD)
            Toggle(model.t("pref.allowExternalUser"), isOn: $prefs.allowExternalUser)
            TextField(model.t("commit.preScript"), text: $prefs.preCommitScript)
            Picker(model.t("transcript.clear"), selection: $prefs.transcriptRetention) {
                Text("replace").tag("replace")
                Text("15m").tag("15m")
                Text("1h").tag("1h")
                Text("1d").tag("1d")
                Text("1w").tag("1w")
                Text("month").tag("month")
            }
        }
    }

    private var security: some View {
        Form {
            TextField(model.t("pref.sshPort"), text: $prefs.sshPort)
            TextField(model.t("pref.sshIdentity"), text: $prefs.sshIdentity)
            TextField(model.t("pref.sshSendEnv"), text: $prefs.sshSendEnv, axis: .vertical)
            TextField(model.t("field.url"), text: $prefs.httpProxyHost)
            TextField(model.t("pref.proxyPort"), text: $prefs.httpProxyPort)
        }
    }

    private var locations: some View {
        Form {
            Toggle(model.t("pref.sharedConfig"), isOn: $prefs.useSharedSVNConfig)
            Toggle(model.t("pref.sharedSSH"), isOn: $prefs.useSharedSSH)
        }
    }

    private var notes: some View {
        Form {
            Toggle(model.t("pref.notifyCheckout"), isOn: $prefs.notifyCheckout)
            Toggle(model.t("pref.notifyUpdate"), isOn: $prefs.notifyUpdate)
            Toggle(model.t("pref.notifyCommit"), isOn: $prefs.notifyCommit)
            Toggle(model.t("pref.notifyImport"), isOn: $prefs.notifyImport)
            Toggle(model.t("pref.notifyExport"), isOn: $prefs.notifyExport)
        }
    }

    private var properties: some View {
        UserPropertiesEditor(model: model, enabled: $prefs.enableUserProperties)
    }
}

struct UserPropertiesEditor: View {
    @Bindable var model: AppModel
    @Binding var enabled: Bool
    @State private var items: [UserPropertyDef] = []

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(model.t("pref.enableUserProps"), isOn: $enabled)
            List {
                ForEach(items) { item in
                    Text("\(item.label.isEmpty ? item.name : item.label)  \(item.type)")
                }
            }
            HStack {
                Button(model.t("action.add")) {
                    items.append(UserPropertyDef(id: UUID().uuidString, name: "prop", label: "", type: "text", options: "", enabled: true))
                    model.library.saveUserProperties(items)
                }
                Button(model.t("action.delete")) {
                    items.removeLast()
                    model.library.saveUserProperties(items)
                }.disabled(items.isEmpty)
            }
        }
        .onAppear { items = model.library.userProperties() }
    }
}
