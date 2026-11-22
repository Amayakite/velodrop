import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeloCore

private enum PreferencesSection: String, CaseIterable, Identifiable {
    case general, downloads, browsers, network
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .downloads: "Downloads"
        case .browsers: "Browsers"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .downloads: "arrow.down.circle"
        case .browsers: "puzzlepiece.extension"
        case .network: "network"
        }
    }

    var tint: Color {
        switch self {
        case .general: .secondary
        case .downloads: VD.accent
        case .browsers: VD.teal
        case .network: VD.purple
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .general: "Choose where files are saved and what happens after a download."
        case .downloads: "Control the queue, connections, and browser confirmations."
        case .browsers: "Connect the VeloDrop extension to Chrome, Edge, Brave, or Vivaldi and review takeover rules."
        case .network: "Set a global bandwidth limit and review proxy behavior."
        }
    }
}

struct PreferencesView: View {
    @Bindable var model: DownloadModel
    @State private var message: String?
    @State private var error = false
    @State private var checkingUpdate = false
    @State private var updateMessage: String?
    @State private var section: PreferencesSection = .general
    @State private var choosingFolder = false
    @State private var checkedAt: Date?
    @State private var browserSetupVersion = 0
    @AppStorage("deleteFilesByDefault") private var deleteFiles = true
    @AppStorage("playCompletionSound") private var playSound = false

    private var extensionFolder: URL {
        BundleLayout.browserExtension(in: Bundle.main.bundleURL)
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
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
                    case .browsers: browsers
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
        .frame(width: 680, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: refreshConnection)
        .onReceive(NotificationCenter.default.publisher(for: .velodropCheckForUpdates)) { _ in
            section = .general
            checkForUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .velodropOpenEdgeSettings)) { _ in
            section = .browsers
            refreshConnection()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if section == .browsers { refreshConnection() }
        }
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
            settingsCard("Application", symbol: "app.badge") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VeloDrop \(currentVersion)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                            Text("Updates replace the running version and reopen the app automatically.")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(checkingUpdate ? "Checking…" : "Check for Updates…", action: checkForUpdates)
                            .buttonStyle(VDSecondaryButtonStyle(compact: true))
                            .disabled(checkingUpdate)
                    }
                    if let updateMessage {
                        Text(updateMessage)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                    Text("Choose VeloDrop, your browser, or cancel in the download confirmation window.")
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

    private var browsers: some View {
        VStack(spacing: 12) {
            connectionCard

            settingsCard("Browser Takeover", symbol: "hand.raised") {
                VStack(spacing: 0) {
                    toggleRow("Take over browser downloads", isOn: $model.browserTakeoverEnabled)
                    Text("Ordinary files that match these rules are offered in VeloDrop instead of in the browser.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(VD.hairline).padding(.leading, 24)

                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Minimum file size")
                                .font(.system(size: 11))
                            Text("Smaller files stay in the browser.")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField("", value: $model.browserMinimumMiB,
                                  format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .onChange(of: model.browserMinimumMiB) { _, value in
                                if value < 0 { model.browserMinimumMiB = 0 }
                                if value > 10_240 { model.browserMinimumMiB = 10_240 }
                            }
                        Text("MiB")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)

                    Divider().overlay(VD.hairline).padding(.leading, 24)

                    toggleRow("Reuse browser session headers", isOn: $model.browserReuseSessionHeaders)
                    Text("Only the accepted download may use its cookies and request headers. Redirects never receive them.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(VD.hairline).padding(.leading, 24)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Keep these sites in the browser")
                                .font(.system(size: 11))
                            Spacer()
                            if excludedHostCount > 0 {
                                Text("\(excludedHostCount) sites")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        TextEditor(text: $model.browserExcludedHosts)
                            .font(.system(size: 10.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 58)
                            .background(Color.primary.opacity(0.035),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(VD.hairline, lineWidth: 0.8)
                            )
                        Text("One domain per line. Rules check the download URL, the final URL, and the page that started it.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 7)
                }
            }

            settingsCard("Browser Connectors", symbol: "link") {
                VStack(alignment: .leading, spacing: 11) {
                    Text("The VeloDrop extension only bridges downloads. It has no settings of its own; everything is managed here.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        ForEach(Array(ChromiumBrowser.supported.enumerated()), id: \.element.id) { index, browser in
                            if index > 0 {
                                Divider().overlay(VD.hairline).padding(.leading, 30)
                            }
                            browserRow(browser)
                        }
                    }
                    .id(browserSetupVersion)

                    step(1, "Choose Set Up Browsers. VeloDrop registers the connector for every installed browser, copies the extension folder path, and opens the extensions page.")
                    step(2, "In the browser, turn on Developer mode and choose Load unpacked. In the folder picker, press ⇧⌘G, paste the path, press Return, then choose Select Folder.")
                    step(3, "That is all. The toolbar icon only shows the bridge status, and the connection appears above.")
                    Text("After updating VeloDrop, reload the extension once in your browser to use the new bridge UI.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Set Up Browsers…", action: install)
                            .buttonStyle(VDPrimaryButtonStyle(compact: true))
                        Button("Copy Extension Path", action: copyPath)
                            .buttonStyle(VDSecondaryButtonStyle(compact: true))
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([extensionFolder]) }
                            .buttonStyle(VDSecondaryButtonStyle(compact: true))
                    }
                    .padding(.top, 1)
                    Text("Works with Chrome, Edge, Brave, and Vivaldi.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                Button("Disconnect", action: disconnect)
                    .buttonStyle(VDDangerButtonStyle(compact: true))
                Spacer()
            }
        }
    }

    private var connectionCard: some View {
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
    }

    private func browserRow(_ browser: ChromiumBrowser) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = browser.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .opacity(browser.isInstalled ? 1 : 0.35)

            VStack(alignment: .leading, spacing: 1) {
                Text(browser.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(browser.isInstalled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(browserStatus(browser))
                    .font(.system(size: 9.5))
                    .foregroundStyle(browser.isInstalled
                                     ? AnyShapeStyle(browser.isRegistered ? VD.green : VD.orange)
                                     : AnyShapeStyle(.tertiary))
            }
            Spacer()
            if browser.isInstalled {
                Button("Open Extensions") { browser.openExtensionsPage() }
                    .buttonStyle(VDSecondaryButtonStyle(compact: true))
            }
        }
        .padding(.vertical, 5)
    }

    private func browserStatus(_ browser: ChromiumBrowser) -> LocalizedStringKey {
        if !browser.isInstalled { return "Not installed" }
        return browser.isRegistered ? "Connector ready" : "Connector not set up"
    }

    private var excludedHostCount: Int {
        model.browserExcludedHosts
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .filter { !$0.isEmpty }
            .count
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
    }

    private func checkForUpdates() {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        updateMessage = String(localized: "Checking for updates…")
        Task {
            do {
                let release = try await UpdateChecker.latest()
                checkingUpdate = false
                updateMessage = nil
                guard UpdateChecker.isNewer(release.version, than: currentVersion) else {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "You’re up to date")
                    alert.informativeText = String(localized: "VeloDrop \(currentVersion) is the newest version.")
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                    return
                }

                let alert = NSAlert()
                alert.messageText = String(localized: "VeloDrop \(release.version) is available")
                alert.informativeText = String(localized: "VeloDrop will quit, replace the old version, and reopen automatically.")
                alert.addButton(withTitle: String(localized: "Download and Install"))
                alert.addButton(withTitle: String(localized: "Release Notes"))
                alert.addButton(withTitle: String(localized: "Later"))
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    checkingUpdate = true
                    updateMessage = String(localized: "Downloading VeloDrop \(release.version)…")
                    try await UpdateInstaller.downloadAndOpen(release)
                    updateMessage = String(localized: "Opening the installer…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
                case .alertSecondButtonReturn:
                    NSWorkspace.shared.open(release.pageURL)
                default:
                    break
                }
            } catch {
                checkingUpdate = false
                updateMessage = error.localizedDescription
            }
        }
    }

    private func install() {
        do {
            let count = try BrowserConnector.registerAll(bundle: Bundle.main.bundleURL)
            guard count > 0 else {
                message = String(localized: "No supported browser was found. Install Chrome, Edge, Brave, or Vivaldi first.")
                error = true
                return
            }
            browserSetupVersion += 1
            copyPath()
            ChromiumBrowser.firstInstalled?.openExtensionsPage()
            message = String(localized: "Browser connector installed. Load the extension in each browser you want to use.")
            error = false
        } catch {
            message = error.localizedDescription
            self.error = true
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
        BrowserConnector.removeAll()
        browserSetupVersion += 1
        message = String(localized: "The connector was removed. You can remove the extension in each browser.")
        error = false
    }
}
