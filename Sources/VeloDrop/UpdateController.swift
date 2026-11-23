import AppKit
import Foundation

struct VeloRelease {
    let version: String
    let dmgURL: URL
    let pageURL: URL
}

enum UpdateError: LocalizedError {
    case invalidFeed
    case noDiskImage
    case mountFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFeed:
            return String(localized: "The update server returned an unexpected response.")
        case .noDiskImage:
            return String(localized: "This release does not include a VeloDrop disk image.")
        case .mountFailed(let message):
            return String(localized: "Couldn’t open the downloaded disk image. \(message)")
        }
    }
}

enum UpdateChecker {
    private struct Release: Decodable {
        let tagName: String
        let pageURL: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let downloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case pageURL = "html_url"
            case assets
        }
    }

    static var feedURL: URL {
        if let override = ProcessInfo.processInfo.environment["VELODROP_UPDATE_FEED"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/Amayakite/velodrop/releases/latest")!
    }

    static func latest() async throws -> VeloRelease {
        let data: Data
        if feedURL.isFileURL {
            data = try Data(contentsOf: feedURL)
        } else {
            var request = URLRequest(url: feedURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("VeloDrop", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateError.invalidFeed
            }
            data = body
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let images = release.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard !images.isEmpty else { throw UpdateError.noDiskImage }
        // Releases may eventually carry more than one architecture. Prefer the
        // image built for this Mac instead of whichever asset happens to be first.
        let asset = images.first { $0.name.lowercased().contains("-macos-" + architecture) } ?? images[0]
        let tag = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return VeloRelease(version: tag, dmgURL: asset.downloadURL, pageURL: release.pageURL)
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = parts(remote)
        let localParts = parts(local)
        for index in 0..<max(remoteParts.count, localParts.count) {
            let left = index < remoteParts.count ? remoteParts[index] : 0
            let right = index < localParts.count ? localParts[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: "-", maxSplits: 1).first?.split(separator: ".").map {
            Int($0) ?? 0
        } ?? []
    }
}

@MainActor
enum UpdateInstaller {
    static func downloadAndOpen(_ release: VeloRelease) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: release.dmgURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.invalidFeed
        }
        let fileManager = FileManager.default
        let dmg = fileManager.temporaryDirectory
            .appendingPathComponent("VeloDrop-\(release.version)-\(UUID().uuidString).dmg")
        try? fileManager.removeItem(at: dmg)
        try fileManager.moveItem(at: temporary, to: dmg)

        let mount = fileManager.temporaryDirectory
            .appendingPathComponent("VeloDrop-mount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mount, withIntermediateDirectories: true)

        func cleanUp() {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            try? fileManager.removeItem(at: mount)
            try? fileManager.removeItem(at: dmg)
        }

        let attached = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly",
                                                "-mountpoint", mount.path, dmg.path])
        guard attached.status == 0 else {
            cleanUp()
            throw UpdateError.mountFailed(attached.message)
        }

        let contents = try fileManager.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])
        guard let installer = contents.first(where: { $0.pathExtension == "app" }) else {
            cleanUp()
            throw UpdateError.mountFailed(String(localized: "The installer app is missing."))
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                // The installer finishes the upgrade unattended and replaces the
                // exact copy that is running now, then cleans up the mount.
                var environment = ["VELODROP_INSTALL_AUTOSTART": "1",
                                   "VELODROP_INSTALL_MOUNT": mount.path,
                                   "VELODROP_INSTALL_ARTIFACT": dmg.path]
                let processEnvironment = ProcessInfo.processInfo.environment
                if let override = processEnvironment["VELODROP_INSTALL_TARGET"] {
                    environment["VELODROP_INSTALL_TARGET"] = override
                } else {
                    let runningApp = Bundle.main.bundleURL
                    if runningApp.pathExtension == "app",
                       FileManager.default.isWritableFile(
                           atPath: runningApp.deletingLastPathComponent().path) {
                        // Replace the exact copy that launched the update. If it
                        // is read-only (for example a translocated disk image),
                        // fall back to the installer's standard location.
                        environment["VELODROP_INSTALL_TARGET"] = runningApp.path
                    }
                }
                if let override = processEnvironment["VELODROP_INSTALL_OPEN"] {
                    environment["VELODROP_INSTALL_OPEN"] = override
                }
                configuration.environment = environment
                NSWorkspace.shared.openApplication(at: installer, configuration: configuration) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            cleanUp()
            throw error
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

extension Notification.Name {
    static let velodropCheckForUpdates = Notification.Name("com.amayakite.velodrop.checkForUpdates")
    static let velodropOpenBrowserSettings = Notification.Name("com.amayakite.velodrop.openBrowserSettings")
}
