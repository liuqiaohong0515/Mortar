import Foundation

enum BundledSVN {
    static func tool(_ name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("SVN.bundle/bin/\(name)"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/SVN.bundle/bin/\(name)"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("SVN.bundle/bin/\(name)"),
        ]
        for url in candidates.compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        for url in candidates.compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static var version: String {
        guard let url = tool("svn") else { return "missing" }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version", "--quiet"]
        process.environment = cleanEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    nonisolated static func cleanEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        env.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH")
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        for (key, value) in extra { env[key] = value }
        return env
    }
}
