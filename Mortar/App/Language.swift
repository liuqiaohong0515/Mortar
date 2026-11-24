import Foundation
import Observation

@Observable
final class LanguageController {
    var code: String
    private var table: [String: [String: String]] = [:]
    static let supported = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "it", "pt-PT", "nl", "sv", "da", "nb", "fi"]

    init(code: String) {
        self.code = code
        load()
    }

    var resolved: String {
        if !code.isEmpty, Self.supported.contains(code) { return code }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if let match = Self.supported.first(where: { preferred.hasPrefix($0) || preferred.replacingOccurrences(of: "_", with: "-").hasPrefix($0) }) {
            return match
        }
        if preferred.hasPrefix("zh") {
            return preferred.contains("Hant") || preferred.contains("TW") || preferred.contains("HK") ? "zh-Hant" : "zh-Hans"
        }
        let base = preferred.split(separator: "-").first.map(String.init) ?? "en"
        return Self.supported.contains(base) ? base : "en"
    }

    var locale: Locale { Locale(identifier: resolved) }

    func t(_ key: String) -> String {
        let language = resolved
        if let value = table[key]?[language], !value.isEmpty { return value }
        if let value = table[key]?["en"], !value.isEmpty { return value }
        return key
    }

    private func load() {
        let candidates = [
            Bundle.main.url(forResource: "LocalizationCatalog", withExtension: "json"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LocalizationCatalog.json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return }
        table = json
    }
}
