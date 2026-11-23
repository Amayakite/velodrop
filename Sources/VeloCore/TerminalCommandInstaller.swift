import Foundation

public enum TerminalCommandInstaller {
    private enum InstallError: LocalizedError {
        case missingCommand, occupied(URL)

        var errorDescription: String? {
            switch self {
            case .missingCommand:
                String(localized: "This copy of VeloDrop is missing the terminal command.")
            case .occupied(let item):
                String(localized: "A command already exists at \(item.path).")
            }
        }
    }

    /// Installs velodrop and returns whether the optional vd shortcut was installed.
    public static func install(in bundle: URL, includeShortCommand: Bool,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               path: String = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin") throws -> Bool {
        let manager = FileManager.default
        let executable = BundleLayout.terminalCommand(in: bundle)
        guard manager.isExecutableFile(atPath: executable.path) else { throw InstallError.missingCommand }
        let destination = home.appendingPathComponent(".local/bin", isDirectory: true)
        var search = path.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        // A GUI launch can inherit a system-only PATH even when the user's
        // shell has Homebrew or a personal bin directory.
        search += [destination, home.appendingPathComponent("bin", isDirectory: true)]

        func isOurLink(_ url: URL) -> Bool {
            guard let target = try? manager.destinationOfSymbolicLink(atPath: url.path) else { return false }
            return URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
                .absoluteURL.standardizedFileURL == executable.standardizedFileURL
        }

        func conflict(for name: String) -> URL? {
            for directory in search {
                let url = directory.appendingPathComponent(name)
                let occupied = manager.fileExists(atPath: url.path)
                    || (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil
                if occupied && !isOurLink(url) { return url }
            }
            return nil
        }

        func link(_ name: String) throws {
            let url = destination.appendingPathComponent(name)
            if !isOurLink(url) { try manager.createSymbolicLink(at: url, withDestinationURL: executable) }
        }

        if let existing = conflict(for: "velodrop") { throw InstallError.occupied(existing) }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try link("velodrop")
        guard includeShortCommand, conflict(for: "vd") == nil else { return false }
        try link("vd")
        return true
    }
}
