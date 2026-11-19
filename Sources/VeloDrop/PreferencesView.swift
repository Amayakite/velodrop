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

private enum PreferencesSection: String, CaseIterable, Identifiable {
    case general, downloads, edge, network
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .downloads: "Downloads"
        case .edge: "Microsoft Edge"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .downloads: "arrow.down.circle"
        case .edge: "puzzlepiece.extension"
        case .network: "network"
        }
    }

    var tint: Color {
        switch self {
        case .general: .secondary
        case .downloads: VD.accent
        case .edge: VD.teal
        case .network: VD.purple
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .general: "Choose where files are saved and what happens after a download."
        case .downloads: "Control the queue, connections, and browser confirmations."
        case .edge: "Connect the browser extension and review takeover rules."
        case .network: "Set a global bandwidth limit and review proxy behavior."
        }
    }
}

struct PreferencesView: View {
    @Bindable var model: DownloadModel
    @State private var message: String?
    @State private var error = false
    @State private var section: PreferencesSection = .general
    @State private var choosingFolder = false
    @State private var checkedAt: Date?
    @State private var rules: BrowserRules?
    @AppStorage("deleteFilesByDefault") private var deleteFiles = true
    @AppStorage("playCompletionSound") private var playSound = false

    private var extensionFolder: URL {
        BundleLayout.browserExtension(in: Bundle.main.bundleURL)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(VD.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    switch section {
                    case .general: general
                    case .downloads: downloads
                    case .edge: edge
                    case .network: network
                    }
                    if let message {
                        Label(message, systemImage: error ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(error ? VD.orange : VD.green)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 680, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: refreshConnection)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do { model.defaultFolder = try result.get().path }
            catch { model.notice = error.localizedDescription }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 17, weight: .bold))
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 14)
            VStack(spacing: 2) {
                ForEach(PreferencesSection.allCases) { item in
                    Button {
                        section = item
                        message = nil
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(section == item ? .white : item.tint)
                                .frame(width: 17)
                            Text(item.title)
                                .font(.system(size: 12, weight: section == item ? .semibold : .regular))
                                .foregroundStyle(section == item ? .white : .primary)
                            Spacer()
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 31)
                        .background {
                            if section == item {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(VD.accentGradient)
                                    .shadow(color: VD.accent.opacity(0.20), radius: 4, x: 0, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            Spacer()
            VStack(alignment: .leading, spacing: 2) {
                Text("Version")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(16)
        }
        .frame(width: 172)
        .background(VD.sidebar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.title)
                .font(.system(size: 21, weight: .bold))
            Text(section.subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    private var general: some View {
        VStack(spacing: 12) {
            settingsCard("Storage", symbol: "externaldrive") {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(VD.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save files to")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text(model.defaultFolder)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Choose Folder…") { choosingFolder = true }
                        .buttonStyle(VDSecondaryButtonStyle(compact: true))
                }
            }
            settingsCard("After Download", symbol: "sparkles") {
                VStack(spacing: 0) {
                    toggleRow("Play a sound when downloads finish", isOn: $playSound)
                    Divider().overlay(VD.hairline).padding(.leading, 24)
                    toggleRow("Show window after takeover", isOn: $model.showWindowOnCapture)
                }
            }
            settingsCard("Delete", symbol: "trash") {
                VStack(alignment: .leading, spacing: 7) {
                    toggleRow("Select file deletion by default", isOn: $deleteFiles)
                    Text("Files will be moved to Trash. Active downloads will be stopped.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
        }
    }

    private var downloads: some View {
        VStack(spacing: 12) {
            settingsCard("Queue", symbol: "list.number") {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("Simultaneous downloads")
                            .font(.system(size: 11))
                        Spacer()
                        Stepper(value: $model.simultaneousDownloads, in: 1...10) {
                            Text("\(model.simultaneousDownloads)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .frame(width: 20)
                        }
                        .fixedSize()
                    }
                    .padding(.vertical, 5)
                    Divider().overlay(VD.hairline)
                    HStack(spacing: 10) {
                        Text("Connections per file")
                            .font(.system(size: 11))
                        Spacer()
                        Picker("Connections per file", selection: $model.maxConnections) {
                            ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .menuStyle(.borderlessButton)
                        .frame(width: 70)
                    }
                    .padding(.vertical, 5)
                }
            }
            settingsCard("Files", symbol: "doc.on.doc") {
                HStack(spacing: 10) {
                    Text("If a file already exists")
                        .font(.system(size: 11))
                    Spacer()
                    Picker("If a file already exists", selection: $model.existingFilePolicy) {
                        Text("Keep both files").tag(ExistingFilePolicy.rename)
                        Text("Skip download").tag(ExistingFilePolicy.skip)
                        Text("Replace existing file").tag(ExistingFilePolicy.replace)
                    }
                    .labelsHidden()
                    .menuStyle(.borderlessButton)
                    .frame(width: 170)
                }
            }
            settingsCard("Browser Takeover", symbol: "safari") {
                VStack(alignment: .leading, spacing: 7) {
                    toggleRow("Confirm browser downloads", isOn: $model.confirmBrowserDownloads)
                    Text("Choose VeloDrop, Edge, or cancel in the download confirmation window.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
        }
    }

    private var network: some View {
        VStack(spacing: 12) {
            settingsCard("Speed Limit", symbol: "speedometer") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text("Total download speed")
                            .font(.system(size: 11))
                        Spacer()
                        Picker("Total download speed", selection: $model.bandwidthLimit) {
                            Text("Unlimited").tag(Int64(0))
                            Text("1 MB/s").tag(Int64(1_000_000))
                            Text("5 MB/s").tag(Int64(5_000_000))
                            Text("10 MB/s").tag(Int64(10_000_000))
                        }
                        .labelsHidden()
                        .menuStyle(.borderlessButton)
                        .frame(width: 130)
                    }
                    Text("Per-download limits and connections can be changed in Download Progress.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            settingsCard("Proxy", symbol: "network") {
                Text("Browser downloads use the captured browser route. Other downloads use the macOS system proxy.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var edge: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((checkedAt == nil ? VD.orange : VD.green).opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(checkedAt == nil ? VD.orange : VD.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(checkedAt == nil ? "Not Connected" : "Connected")
                        .font(.system(size: 12.5, weight: .semibold))
                    if let checkedAt {
                        Text("Last connected \(Format.dateTime(checkedAt))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No connection check received yet.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Refresh Connection", action: refreshConnection)
                    .buttonStyle(VDSecondaryButtonStyle(compact: true))
            }
            .vdCard(padding: 12)

            settingsCard("Connect Microsoft Edge", symbol: "link") {
                VStack(alignment: .leading, spacing: 11) {
                    step(1, "Set Up Edge opens the extensions page and copies the extension folder path.")
                    step(2, "Turn on Developer mode in Edge and choose Load unpacked. In the folder picker, press ⇧⌘G, paste the path, press Return, then choose Select Folder.")
                    step(3, "Open the VeloDrop extension in Edge, then check the connection here.")
                    HStack(spacing: 8) {
                        Button("Set Up Edge…", action: install)
                            .buttonStyle(VDPrimaryButtonStyle(compact: true))
                        Button("Copy Extension Path", action: copyPath)
                            .buttonStyle(VDSecondaryButtonStyle(compact: true))
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([extensionFolder]) }
                            .buttonStyle(VDSecondaryButtonStyle(compact: true))
                    }
                    .padding(.top, 1)
                }
            }

            settingsCard("Browser Rules", symbol: "slider.horizontal.3") {
                if let rules {
                    VStack(spacing: 0) {
                        ruleRow("Take over downloads", rules.enabled ? String(localized: "Enabled") : String(localized: "Disabled"),
                                tint: rules.enabled ? VD.green : .secondary)
                        Divider().overlay(VD.hairline)
                        ruleRow("Minimum file size", "\(rules.minimumMiB.formatted()) MiB")
                        Divider().overlay(VD.hairline)
                        ruleRow("Excluded websites", rules.excludedHosts.isEmpty ? String(localized: "None") : rules.excludedHosts)
                    }
                    Text("Change these rules in the VeloDrop extension, then refresh here.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 7)
                } else {
                    Text("Open the VeloDrop extension in Edge to check its connection and set excluded websites and minimum file size.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button("Open Extensions") { openEdge("edge://extensions/") }
                    .buttonStyle(VDSecondaryButtonStyle(compact: true))
                Button("Disconnect", action: disconnect)
                    .buttonStyle(VDDangerButtonStyle(compact: true))
                Spacer()
            }
        }
    }

    private func settingsCard<Content: View>(_ title: LocalizedStringKey, symbol: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(VD.accent)
                SectionEyebrow(text: title)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vdCard(padding: 13)
    }

    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func ruleRow(_ title: LocalizedStringKey, _ value: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(VD.accent.opacity(0.85), in: Circle())
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
