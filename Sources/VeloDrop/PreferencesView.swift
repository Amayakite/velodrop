import AppKit
import CryptoKit
import SwiftUI
import VeloCore

private struct EdgeRegistration {
    let bundle: URL

    private var hostManifest: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Microsoft Edge/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent(BundleLayout.identifier + ".json")
    }

    func install() throws -> URL {
        let extensionFolder = BundleLayout.browserExtension(in: bundle)
        let data = try Data(contentsOf: extensionFolder.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = manifest["key"] as? String, let spki = Data(base64Encoded: key),
              FileManager.default.isExecutableFile(atPath: BundleLayout.bridge(in: bundle).path) else {
            throw TransferError.engineUnavailable
        }
        let alphabet = Array("abcdefghijklmnop")
        let id = String(SHA256.hash(data: spki).prefix(16).flatMap {
            [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]]
        })
        let host = [
            "name": BundleLayout.identifier,
            "description": "VeloDrop download handoff",
            "path": BundleLayout.bridge(in: bundle).path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(id)/"],
        ] as [String: Any]
        try FileManager.default.createDirectory(at: hostManifest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: host, options: [.prettyPrinted, .sortedKeys])
            .write(to: hostManifest, options: .atomic)
        return extensionFolder
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: hostManifest.path) else { return }
        try FileManager.default.removeItem(at: hostManifest)
    }
}

struct PreferencesView: View {
    @Bindable var model: DownloadModel
    @State private var message: String?
    @State private var error = false

    var body: some View {
        Form {
            Section("Downloads") {
                Picker("Connections per file", selection: $model.maxConnections) {
                    ForEach([1, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledContent("Save files to", value: model.workspace.destination.path(percentEncoded: false))
                    .lineLimit(1).truncationMode(.head)
            }

            Section("Microsoft Edge") {
                Text("Register VeloDrop, then turn on Developer mode in Edge and choose Load unpacked. Select the EdgeExtension folder shown in Finder.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Set Up Edge…", action: install)
                    Button("Disconnect", action: disconnect)
                }
                if let message {
                    Label(message, systemImage: error ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(error ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("VeloDrop Settings")
    }

    private func install() {
        do {
            let folder = try EdgeRegistration(bundle: Bundle.main.bundleURL).install()
            if let edge = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.edgemac"),
               let url = URL(string: "edge://extensions/") {
                NSWorkspace.shared.open([url], withApplicationAt: edge, configuration: NSWorkspace.OpenConfiguration(),
                                        completionHandler: nil)
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            message = String(localized: "The Edge connector is registered. Load the extension from Finder.")
            error = false
        } catch {
            message = error.localizedDescription
            self.error = true
        }
    }

    private func disconnect() {
        do {
            try EdgeRegistration(bundle: Bundle.main.bundleURL).remove()
            message = String(localized: "The connector was removed. You can remove the extension in Edge.")
            error = false
        } catch {
            message = error.localizedDescription
            self.error = true
        }
    }
}
