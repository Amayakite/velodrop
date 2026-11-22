import AppKit
import CryptoKit
import Foundation
import VeloCore

/// A Chromium-based browser that can load the VeloDrop extension and read a
/// user-level native messaging host manifest on macOS.
struct ChromiumBrowser: Identifiable {
    let id: String
    let name: String
    let bundleIdentifier: String
    /// Path under ~/Library/Application Support that owns NativeMessagingHosts.
    let supportFolder: String
    let extensionsAddress: String
    let logoName: String

    static let supported: [ChromiumBrowser] = [
        ChromiumBrowser(id: "chrome", name: "Google Chrome",
                        bundleIdentifier: "com.google.Chrome",
                        supportFolder: "Google/Chrome",
                        extensionsAddress: "chrome://extensions/",
                        logoName: "chrome"),
        ChromiumBrowser(id: "edge", name: "Microsoft Edge",
                        bundleIdentifier: "com.microsoft.edgemac",
                        supportFolder: "Microsoft Edge",
                        extensionsAddress: "edge://extensions/",
                        logoName: "edge"),
        ChromiumBrowser(id: "brave", name: "Brave",
                        bundleIdentifier: "com.brave.Browser",
                        supportFolder: "BraveSoftware/Brave-Browser",
                        extensionsAddress: "brave://extensions/",
                        logoName: "brave"),
        ChromiumBrowser(id: "vivaldi", name: "Vivaldi",
                        bundleIdentifier: "com.vivaldi.Vivaldi",
                        supportFolder: "Vivaldi",
                        extensionsAddress: "vivaldi://extensions/",
                        logoName: "vivaldi"),
    ]

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var isInstalled: Bool { appURL != nil }

    var hostManifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(supportFolder)/NativeMessagingHosts",
                                    isDirectory: true)
            .appendingPathComponent(BundleLayout.identifier + ".json")
    }

    var isRegistered: Bool {
        FileManager.default.fileExists(atPath: hostManifestURL.path)
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

    func openExtensionsPage() {
        guard let appURL, let url = URL(string: extensionsAddress) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }

    static var firstInstalled: ChromiumBrowser? {
        supported.first { $0.isInstalled }
    }
}

/// Writes the native messaging host manifest that lets a browser discover
/// VeloBridge. Chromium browsers read one directory per browser profile root.
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
    static func register(_ browser: ChromiumBrowser, bundle: URL) throws -> Bool {
        guard browser.isInstalled else { return false }
        guard FileManager.default.isExecutableFile(atPath: BundleLayout.bridge(in: bundle).path) else {
            throw TransferError.engineUnavailable
        }
        let origin = "chrome-extension://\(try extensionIdentifier(in: bundle))/"
        let host: [String: Any] = [
            "name": BundleLayout.identifier,
            "description": "VeloDrop download handoff",
            "path": BundleLayout.bridge(in: bundle).path,
            "type": "stdio",
            "allowed_origins": [origin],
        ]
        let manifest = browser.hostManifestURL
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: host, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifest, options: .atomic)
        return true
    }

    /// Registers every installed supported browser and returns the count.
    @discardableResult
    static func registerAll(bundle: URL) throws -> Int {
        var count = 0
        for browser in ChromiumBrowser.supported where browser.isInstalled {
            if try register(browser, bundle: bundle) { count += 1 }
        }
        return count
    }

    static func removeAll() {
        for browser in ChromiumBrowser.supported {
            try? FileManager.default.removeItem(at: browser.hostManifestURL)
        }
    }
}
