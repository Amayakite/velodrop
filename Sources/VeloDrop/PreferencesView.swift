import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import VeloCore

private struct EdgeRegistration {
    let bundle: URL

    private var hostManifest: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Microsoft Edge/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent(BundleLayout.identifier + ".json")
    }

    func install() throws {
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
    @State private var section = "General"
    @State private var choosingFolder = false
    @State private var checkedAt: Date?
    @State private var rules: BrowserRules?
    @AppStorage("deleteFilesByDefault") private var deleteFiles = true
    @AppStorage("playCompletionSound") private var playSound = false

    private var extensionFolder: URL {
        BundleLayout.browserExtension(in: Bundle.main.bundleURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $section) {
                Text("General").tag("General")
                Text("Downloads").tag("Downloads")
                Text("Microsoft Edge").tag("Edge")
                Text("Network").tag("Network")
            }.pickerStyle(.segmented).padding(18)
            Form {
                if section == "General" {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    Section("Save files to") {
                        Text(model.defaultFolder).textSelection(.enabled)
                        Button("Choose Folder…") { choosingFolder = true }
                    }
                    Section("After Download") {
                        Toggle("Play a sound when downloads finish", isOn: $playSound)
                        Toggle("Show window after takeover", isOn: $model.showWindowOnCapture)
                    }
                    Section("Delete") {
                        Toggle("Select file deletion by default", isOn: $deleteFiles)
                        Text("Files will be moved to Trash. Active downloads will be stopped.")
                            .foregroundStyle(.secondary)
                    }
                }
                if section == "Downloads" {
                    Section("Downloads") {
                        Stepper("Simultaneous downloads: \(model.simultaneousDownloads)", value: $model.simultaneousDownloads, in: 1...10)
                        Picker("Connections per file", selection: $model.maxConnections) {
                            ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                        }
                        ExistingFilePicker(selection: $model.existingFilePolicy)
                        Toggle("Confirm browser downloads", isOn: $model.confirmBrowserDownloads)
                        Text("Choose VeloDrop, Edge, or cancel in the download confirmation window.")
                            .foregroundStyle(.secondary)
                    }
                }
                if section == "Network" {
                    Section("Speed Limit") {
                        Picker("Total download speed", selection: $model.bandwidthLimit) {
                            Text("Unlimited").tag(Int64(0))
                            Text("1 MB/s").tag(Int64(1_000_000))
                            Text("5 MB/s").tag(Int64(5_000_000))
                            Text("10 MB/s").tag(Int64(10_000_000))
                        }
                        Text("Per-download limits and connections can be changed in Download Progress.")
                            .foregroundStyle(.secondary)
                    }
                    Section("Proxy") {
                        Text("Browser downloads use the captured browser route. Other downloads use the macOS system proxy.")
                            .foregroundStyle(.secondary)
                    }
                }
                if section == "Edge" {
                    Section("Connect Microsoft Edge") {
                        Text("Set Up Edge opens the extensions page and copies the extension folder path.")
                        Button("Set Up Edge…", action: install)
                        Text("Turn on Developer mode in Edge and choose Load unpacked. In the folder picker, press ⇧⌘G, paste the path, press Return, then choose Select Folder.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Copy Extension Path", action: copyPath)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([extensionFolder]) }
                        }
                    }
                    Section("Check Connection") {
                        if let checkedAt {
                            Text("Last connected \(checkedAt.formatted(date: .abbreviated, time: .standard))")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No connection check received yet.").foregroundStyle(.secondary)
                        }
                        Button("Refresh Connection", action: refreshConnection)
                        Text("Open the VeloDrop extension in Edge to check its connection and set excluded websites and minimum file size.")
                            .foregroundStyle(.secondary)
                        Button("Open Extensions") { openEdge("edge://extensions/") }
                        Button("Disconnect", action: disconnect)
                    }
                    if let rules {
                        Section("Browser Rules") {
                            LabeledContent("Take over downloads", value: rules.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                            LabeledContent("Minimum file size", value: "\(rules.minimumMiB.formatted()) MiB")
                            LabeledContent("Excluded websites", value: rules.excludedHosts.isEmpty ? String(localized: "None") : rules.excludedHosts)
                            Text("Change these rules in the VeloDrop extension, then refresh here.").foregroundStyle(.secondary)
                        }
                    }
                    if let message {
                        Label(message, systemImage: error ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(error ? .orange : .secondary)
                    }
                }
            }.formStyle(.grouped)
        }
        .onAppear(perform: refreshConnection)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do { model.defaultFolder = try result.get().path }
            catch { model.notice = error.localizedDescription }
        }
    }

    private func refreshConnection() {
        checkedAt = model.lastBrowserConnection
        if let data = try? Data(contentsOf: model.workspace.root.appendingPathComponent("browser-rules.json")) {
            rules = try? JSONDecoder().decode(BrowserRules.self, from: data)
        }
    }

    private func install() {
        do {
            try EdgeRegistration(bundle: Bundle.main.bundleURL).install()
            copyPath()
            openEdge("edge://extensions/")
        } catch {
            message = error.localizedDescription
            self.error = true
        }
    }

    private func openEdge(_ address: String) {
        if let edge = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.edgemac"),
           let url = URL(string: address) {
            NSWorkspace.shared.open([url], withApplicationAt: edge, configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        }
    }

    private func copyPath() {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        let copied = clipboard.setString(extensionFolder.path(percentEncoded: false), forType: .string)
        message = copied
            ? String(localized: "Extension path copied.")
            : String(localized: "Couldn’t copy the extension path. You can open the folder in Finder.")
        error = !copied
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
