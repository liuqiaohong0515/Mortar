import Foundation

actor SVNExecutor {
    static let shared = SVNExecutor()

    private var writeLocks: [String: Int] = [:]

    func run(
        tool: String = "svn",
        arguments: [String],
        workingDirectory: URL? = nil,
        username: String? = nil,
        password: String? = nil,
        trustFailures: Bool = false,
        ssh: SSHOptions? = nil
    ) async throws -> SVNOutput {
        guard let executable = BundledSVN.tool(tool) else {
            throw SVNClientError.missingTool(tool)
        }
        let lockKey = workingDirectory?.path ?? "*"
        if tool == "svn", isWrite(arguments) {
            while writeLocks[lockKey, default: 0] > 0 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            writeLocks[lockKey, default: 0] += 1
        }
        defer {
            if tool == "svn", isWrite(arguments) {
                writeLocks[lockKey, default: 1] -= 1
            }
        }

        var args = arguments
        if tool == "svn" {
            if !args.contains("--non-interactive") { args.append("--non-interactive") }
            if trustFailures, !args.contains(where: { $0.hasPrefix("--trust-server-cert") }) {
                args.append("--trust-server-cert-failures=unknown-ca,cn-mismatch,expired,not-yet-valid,other")
            }
            if let username, !username.isEmpty, !args.contains("--username") {
                args.append(contentsOf: ["--username", username])
            }
            if let password, !password.isEmpty, !args.contains("--password") {
                args.append(contentsOf: ["--password", password, "--no-auth-cache"])
            }
        }

        let output = try await launch(executable, args, workingDirectory, ssh: ssh)
        return output
    }

    private func launch(_ executable: URL, _ arguments: [String], _ cwd: URL?, ssh: SSHOptions?) async throws -> SVNOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                var extra: [String: String] = [:]
                if let ssh, let command = ssh.command { extra["SVN_SSH"] = command }
                process.environment = BundledSVN.cleanEnvironment(extra: extra)
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    let outputQueue = DispatchQueue(label: "svn-output", attributes: .concurrent)
                    let group = DispatchGroup()
                    var outData = Data()
                    var errData = Data()
                    group.enter()
                    outputQueue.async {
                        outData = stdout.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    outputQueue.async {
                        errData = stderr.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    process.waitUntilExit()
                    group.wait()
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    let shown = SVNExecutor.redact(arguments)
                    continuation.resume(returning: SVNOutput(
                        code: process.terminationStatus,
                        stdout: outData,
                        stderr: err,
                        command: executable.lastPathComponent + " " + shown
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func redact(_ arguments: [String]) -> String {
        var parts: [String] = []
        var hideNext = false
        for argument in arguments {
            if hideNext {
                parts.append("••••")
                hideNext = false
                continue
            }
            if argument == "--password" { hideNext = true }
            parts.append(argument.contains(" ") ? "\"\(argument)\"" : argument)
        }
        return parts.joined(separator: " ")
    }

    private func isWrite(_ arguments: [String]) -> Bool {
        let writes: Set<String> = [
            "commit", "update", "checkout", "switch", "merge", "revert", "add", "delete", "rm",
            "mkdir", "import", "move", "mv", "copy", "cp", "lock", "unlock", "resolve", "upgrade",
            "cleanup", "patch", "propset", "propdel", "relocate", "export",
        ]
        return arguments.contains { writes.contains($0) }
    }
}

struct SSHOptions: Sendable {
    var port: String = ""
    var identityFile: String = ""
    var sendEnv: String = ""
    var acceptNew: Bool = true

    var command: String? {
        var parts = ["/usr/bin/ssh"]
        if acceptNew { parts.append("-o StrictHostKeyChecking=accept-new") }
        if !port.isEmpty { parts.append(contentsOf: ["-p", port]) }
        if !identityFile.isEmpty { parts.append(contentsOf: ["-i", identityFile]) }
        if !sendEnv.isEmpty {
            for line in sendEnv.split(separator: "\n") where line.contains("=") {
                parts.append(contentsOf: ["-o", "SendEnv=\(line)"])
            }
        }
        return parts.joined(separator: " ")
    }
}

enum SVNClientError: Error, LocalizedError {
    case missingTool(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingTool(let name): return "Bundled \(name) is missing."
        case .failed(let message): return message
        }
    }
}
