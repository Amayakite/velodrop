import AppKit
import CryptoKit
import Foundation
import SwiftUI
import VeloCore

enum BrowserFamily {
    case chromium
    case firefox
}

/// A browser that can load the VeloDrop extension and read a user-level native
/// messaging host manifest on macOS.
struct SupportedBrowser: Identifiable {
    let id: BrowserID
    let name: String
    let family: BrowserFamily
    /// Path under ~/Library/Application Support that owns NativeMessagingHosts.
    let supportFolder: String
    let installationAddress: String
    let logoName: String

    static let supported: [SupportedBrowser] = [
        SupportedBrowser(id: .chrome, name: "Google Chrome", family: .chromium,
                         supportFolder: "Google/Chrome",
                         installationAddress: "chrome://extensions/",
                         logoName: "chrome"),
        SupportedBrowser(id: .edge, name: "Microsoft Edge", family: .chromium,
                         supportFolder: "Microsoft Edge",
                         installationAddress: "edge://extensions/",
                         logoName: "edge"),
        SupportedBrowser(id: .brave, name: "Brave", family: .chromium,
                         supportFolder: "BraveSoftware/Brave-Browser",
                         installationAddress: "brave://extensions/",
                         logoName: "brave"),
        SupportedBrowser(id: .vivaldi, name: "Vivaldi", family: .chromium,
                         supportFolder: "Vivaldi",
                         installationAddress: "vivaldi://extensions/",
                         logoName: "vivaldi"),
        SupportedBrowser(id: .firefox, name: "Firefox", family: .firefox,
                         supportFolder: "",
                         installationAddress: "about:debugging#/runtime/this-firefox",
                         logoName: "firefox"),
    ]

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.bundleIdentifier)
    }

    var isInstalled: Bool { appURL != nil }

    var hostManifestURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory: URL
        switch family {
        case .chromium:
            directory = base.appendingPathComponent("\(supportFolder)/NativeMessagingHosts", isDirectory: true)
        case .firefox:
            directory = base.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true)
        }
        return directory.appendingPathComponent(BundleLayout.identifier + ".json")
    }

    var isRegistered: Bool {
        guard let data = try? Data(contentsOf: hostManifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = manifest["path"] as? String else { return false }
        let expected = BundleLayout.bridge(in: Bundle.main.bundleURL)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath() == expected.resolvingSymlinksInPath()
            && FileManager.default.isExecutableFile(atPath: path)
    }

    var icon: NSImage? {
        if let url = Bundle.main.url(forResource: logoName, withExtension: "png",
                                     subdirectory: "BrowserLogos"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // The development build has no bundled resources; fall back to the
        // installed browser's own icon.
        return appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    func extensionFolder(in bundle: URL) -> URL {
        switch family {
        case .chromium: BundleLayout.browserExtension(in: bundle)
        case .firefox: BundleLayout.firefoxExtension(in: bundle)
        }
    }

    /// Chromium load-unpacked selects a folder; Firefox selects manifest.json.
    func extensionSelectionPath(in bundle: URL) -> String {
        switch family {
        case .chromium:
            extensionFolder(in: bundle).path(percentEncoded: false)
        case .firefox:
            extensionFolder(in: bundle).appendingPathComponent("manifest.json").path(percentEncoded: false)
        }
    }

    func openInstallPage() {
        if let url = URL(string: installationAddress) { open(url) }
    }

    func open(_ url: URL, activates: Bool = true) {
        guard let appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: configuration,
                                completionHandler: nil)
    }

}

/// Writes the native messaging host manifest that lets a browser discover
/// VeloBridge. Chromium browsers and Firefox read different directories and
/// authorize the extension with different fields.
enum BrowserConnector {
    static func extensionIdentifier(in bundle: URL) throws -> String {
        let manifestURL = BundleLayout.browserExtension(in: bundle).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = manifest["key"] as? String,
              let spki = Data(base64Encoded: key) else {
            throw TransferError.engineUnavailable
        }
        // Chromium derives extension IDs from the SHA-256 of the public key.
        let alphabet = Array("abcdefghijklmnop")
        return String(SHA256.hash(data: spki).prefix(16).flatMap {
            [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]]
        })
    }

    @discardableResult
    static func register(_ browser: SupportedBrowser, bundle: URL) throws -> Bool {
        guard browser.isInstalled else { return false }
        guard FileManager.default.isExecutableFile(atPath: BundleLayout.bridge(in: bundle).path) else {
            throw TransferError.engineUnavailable
        }
        var host: [String: Any] = [
            "name": BundleLayout.identifier,
            "description": "VeloDrop download handoff",
            "path": BundleLayout.bridge(in: bundle).path,
            "type": "stdio",
        ]
        switch browser.family {
        case .chromium:
            host["allowed_origins"] = ["chrome-extension://\(try extensionIdentifier(in: bundle))/"]
        case .firefox:
            host["allowed_extensions"] = [try firefoxIdentifier(in: bundle)]
        }
        let manifest = browser.hostManifestURL
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: host, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifest, options: .atomic)
        return true
    }

    /// Firefox authorizes native messaging with the add-on ID from its Gecko
    /// manifest rather than a key hash.
    static func firefoxIdentifier(in bundle: URL) throws -> String {
        let manifestURL = BundleLayout.firefoxExtension(in: bundle).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = manifest["browser_specific_settings"] as? [String: Any],
              let gecko = settings["gecko"] as? [String: Any],
              let identifier = gecko["id"] as? String else {
            throw TransferError.engineUnavailable
        }
        return identifier
    }

    static func remove(_ browser: SupportedBrowser) throws {
        let manifest = browser.hostManifestURL
        if FileManager.default.fileExists(atPath: manifest.path) {
            try FileManager.default.removeItem(at: manifest)
        }
    }
}
