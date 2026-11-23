import AppKit
import Darwin
import Foundation
import VeloCore

private let usage = """
Usage: velodrop [options] URL [URL ...]

  --connections N  Set the connection limit per file (1–16).
  --dir PATH       Save files to PATH, relative to the current directory.
  --no-ui          Submit without bringing the downloads window forward.
  --wait           Wait for all downloads and report their exit status.
  --version        Print the bundled VeloDrop version.
  --help           Show this help.
"""

private struct UsageError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private enum CommandError: LocalizedError {
    case missingApp, launchTimedOut, acceptanceTimedOut, appStopped

    var errorDescription: String? {
        switch self {
        case .missingApp: "The terminal command must run from an installed VeloDrop app."
        case .launchTimedOut: "VeloDrop did not start. Try opening it from Applications."
        case .acceptanceTimedOut: "VeloDrop hasn't accepted every submitted task. Check its downloads window before retrying."
        case .appStopped: "VeloDrop quit while downloads were pending. Open it again to resume."
        }
    }
}

private struct Options {
    var connections: Int?
    var directory: String?
    var showWindow = true
    var wait = false
    var urls: [URL] = []

    init(_ arguments: [String]) throws {
        var remaining = arguments.makeIterator()
        var readsOptions = true
        while let argument = remaining.next() {
            if readsOptions && argument == "--" {
                readsOptions = false
            } else if readsOptions && argument.hasPrefix("-") {
                let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                switch parts[0] {
                case "--connections":
                    let value = parts.count == 2 ? String(parts[1]) : remaining.next()
                    guard let value, let count = Int(value), (1...16).contains(count) else {
                        throw UsageError("--connections requires an integer from 1 to 16.")
                    }
                    connections = count
                case "--dir":
                    let value = parts.count == 2 ? String(parts[1]) : remaining.next()
                    guard let value, !value.isEmpty, parts.count == 2 || !value.hasPrefix("--") else {
                        throw UsageError("--dir requires a directory path.")
                    }
                    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    let path = (value as NSString).expandingTildeInPath
                    let folder = URL(fileURLWithPath: path, isDirectory: true, relativeTo: cwd)
                        .absoluteURL.standardizedFileURL
                    var isDirectory = ObjCBool(false)
                    if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                       !isDirectory.boolValue {
                        throw UsageError("The path supplied to --dir is not a directory.")
                    }
                    directory = folder.path
                case "--no-ui" where parts.count == 1: showWindow = false
                case "--wait" where parts.count == 1: wait = true
                default: throw UsageError("Unknown option. See velodrop --help.")
                }
            } else {
                guard let url = URL(string: argument), Transfer.supports(url) else {
                    throw UsageError("Download URL \(urls.count + 1) must be an HTTP or HTTPS URL.")
                }
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { throw UsageError("Provide at least one HTTP or HTTPS URL.") }
    }
}

@main
struct TerminalCLI {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(usage)
            return
        }
        do {
            if arguments == ["--version"] {
                let app = try containingApp()
                print("VeloDrop \(app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
                return
            }

            let options = try Options(arguments)
            let transfers = try options.urls.map { url in
                var transfer = try Transfer(url: url)
                transfer.connectionLimit = options.connections
                transfer.destinationPath = options.directory
                return transfer
            }
            let app = try containingApp()
            let workspace = Workspace.standard()
            try workspace.prepare()
            try workspace.submit(TerminalSubmission(transfers: transfers, showWindow: options.showWindow))
            for transfer in transfers { print(transfer.id.uuidString) }
            fflush(stdout)

            let launched = try await launchIfNeeded(app.bundleURL, workspace: workspace, activate: options.showWindow)
            if options.showWindow && !launched {
                // On macOS 14 and later, LaunchServices handles activation
                // from the invoking terminal even if the app is already running.
                try? await openApp(app.bundleURL, activate: true)
            }
            if options.wait {
                let completed = try await waitForDownloads(transfers, workspace: workspace)
                if !completed { exit(1) }
            }
        } catch {
            report(error.localizedDescription)
            exit(error is UsageError ? 2 : 1)
        }
    }

    private static func containingApp() throws -> Bundle {
        var size: UInt32 = UInt32(MAXPATHLEN)
        var path = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&path, &size) != 0 {
            path = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&path, &size) == 0 else { throw CommandError.missingApp }
        }
        let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        let url = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard url.pathExtension == "app", let app = Bundle(url: url),
              app.executableURL?.lastPathComponent == "VeloDrop" else { throw CommandError.missingApp }
        return app
    }

    @MainActor
    private static func launchIfNeeded(_ app: URL, workspace: Workspace, activate: Bool) async throws -> Bool {
        guard !workspace.appIsRunning else { return false }
        // Only one concurrent terminal invocation should ask LaunchServices to
        // start the app. The app's workspace lock confirms its intake is alive.
        let path = workspace.root.appendingPathComponent("terminal-launch.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard !workspace.appIsRunning else { return false }
        try await openApp(app, activate: activate)

        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !workspace.appIsRunning {
            guard ContinuousClock.now < deadline else { throw CommandError.launchTimedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    @MainActor
    private static func openApp(_ app: URL, activate: Bool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.addsToRecentItems = false
        var environment = ["VELODROP_BACKGROUND_LAUNCH": "1"]
        for key in ["VELODROP_DATA", "VELODROP_DESTINATION", "VELODROP_ENGINE"] {
            environment[key] = ProcessInfo.processInfo.environment[key]
        }
        configuration.environment = environment
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    private static func waitForDownloads(_ transfers: [Transfer], workspace: Workspace) async throws -> Bool {
        let acceptanceDeadline = ContinuousClock.now.advanced(by: .seconds(12))
        var pending = transfers
        var succeeded = true
        var stoppedAt: ContinuousClock.Instant?

        while !pending.isEmpty {
            pending = try pending.filter { transfer in
                guard let status = workspace.status(transfer.id) else {
                    guard ContinuousClock.now < acceptanceDeadline else { throw CommandError.acceptanceTimedOut }
                    return true
                }
                guard status.state.terminal else { return true }
                if status.state != .completed {
                    succeeded = false
                    let detail = workspace.read(transfer.id)?.message ?? status.state.rawValue
                    report("\(transfer.id.uuidString) \(transfer.name): \(detail)")
                }
                return false
            }
            guard !pending.isEmpty else { break }
            if workspace.appIsRunning {
                stoppedAt = nil
            } else {
                let stopped = stoppedAt ?? ContinuousClock.now
                stoppedAt = stopped
                if stopped.duration(to: .now) >= .seconds(3) { throw CommandError.appStopped }
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        return succeeded
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("velodrop: \(message)\n".utf8))
    }
}
