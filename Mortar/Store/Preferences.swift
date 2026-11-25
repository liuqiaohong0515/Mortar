import Foundation

struct Preferences: Codable, Equatable {
    var language: String = ""
    var doubleClick: String = "open"
    var fontName: String = "Menlo"
    var fontSize: Double = 12
    var tabWidth: Int = 4
    var fontSmoothing: Bool = true
    var compareTool: String = ""
    var mergeTool: String = ""
    var showInline: Bool = true
    var showLineNumbers: Bool = true
    var showWhitespace: Bool = false
    var showLineEndings: Bool = false
    var showInvisibles: Bool = false
    var showAnnotations: Bool = false
    var globalIgnores: String = "*.o *.lo *.la #*# .*.rej *.rej .*~ *~ .#* .DS_Store"
    var useCommitTimes: Bool = false
    var showTranscriptOnUpdate: Bool = true
    var allowExternalHEAD: Bool = false
    var allowExternalUser: Bool = false
    var preCommitScript: String = ""
    var useSharedSVNConfig: Bool = true
    var useSharedSSH: Bool = true
    var notifyCheckout: Bool = false
    var notifyUpdate: Bool = false
    var notifyCommit: Bool = false
    var notifyImport: Bool = false
    var notifyExport: Bool = false
    var enableUserProperties: Bool = true
    var commitLogFontSize: Double = 13
    var autoProps: Bool = false
    var autoPropsRules: String = ""
    var savePasswords: Bool = true
    var clientCertificate: String = ""
    var proxyUser: String = ""
    var proxyPassword: String = ""
    var transcriptRetention: String = "month"
    var sshPort: String = ""
    var sshIdentity: String = ""
    var sshSendEnv: String = ""
    var httpProxyHost: String = ""
    var httpProxyPort: String = ""

    static let defaultsKey = "MortarPreferences"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let freshData = try? JSONEncoder().encode(Preferences()),
              var fresh = try? JSONSerialization.jsonObject(with: freshData) as? [String: Any] else { return Preferences() }
        for (key, value) in stored { fresh[key] = value }
        guard let merged = try? JSONSerialization.data(withJSONObject: fresh),
              let value = try? JSONDecoder().decode(Preferences.self, from: merged) else { return Preferences() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        UserDefaults.standard.set(transcriptRetention, forKey: "transcriptRetention")
    }
}
