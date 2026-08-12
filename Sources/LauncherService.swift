import AppKit

/// Filesystem locations, CLI detection, and process helpers shared by the app.
///
/// The distributable app cannot rely on a sibling project folder: a DMG is
/// read-only and users commonly move only the `.app` into Applications. The
/// launcher therefore lives inside the app bundle and all mutable data goes
/// to the user's Application Support folder.
///
/// The Application Support folder is intentionally the same "Model Compare"
/// directory used by the previous app, so saved chats and past results carry
/// over to this rewrite.
enum LauncherService {
    static var appResources: URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
    }

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("Model Compare", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var runner: URL { appResources.appendingPathComponent("ask-all.zsh") }

    static var results: URL {
        let directory = applicationSupport.appendingPathComponent("results", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var workDirectory: URL {
        let directory = applicationSupport.appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Locates a provider's CLI: provider-specific install locations first,
    /// then common bin directories, then PATH entries.
    static func executableURL(for provider: ProviderID) -> URL? {
        guard let command = provider.cliCommand else { return nil }
        var candidates = provider.cliCandidatePaths
        candidates += [
            "\(NSHomeDirectory())/.local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
        ]
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/\(command)" }
        candidates += pathEntries
        let fileManager = FileManager.default
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))\""
    }

    /// Opens Terminal running the provider's interactive sign-in flow.
    /// Returns nil on success, or an error description.
    @discardableResult
    static func openTerminalSignIn(command: String) -> String? {
        let script = "tell application \"Terminal\" to activate\ntell application \"Terminal\" to do script \(appleScriptString(command))\nend tell"
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        launcher.arguments = ["-e", script]
        do {
            try launcher.run()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
