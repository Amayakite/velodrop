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
        case .browsers: "Connect the VeloDrop extension to Chrome, Edge, Brave, Vivaldi, or Firefox and review takeover rules."
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
    @State private var section: PreferencesSection
    @State private var choosingFolder = false
    @State private var connections: [BrowserID: BrowserConnection] = [:]
    @State private var verified: [BrowserID: BrowserConnection] = [:]
    @State private var setupBrowser: SupportedBrowser?
    @State private var setupError: String?
    @State private var disconnectConfirmation: SupportedBrowser?
    @State private var browserSetupVersion = 0
    @AppStorage("deleteFilesByDefault") private var deleteFiles = true
    @AppStorage("playCompletionSound") private var playSound = false

    init(model: DownloadModel, showBrowsers: Bool = false) {
        self.model = model
        _section = State(initialValue: showBrowsers ? .browsers : .general)
    }

    private var signedFirefoxExtension: URL? {
        Bundle.main.url(forResource: "VeloDrop-Firefox", withExtension: "xpi")
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
        .onAppear(perform: refreshConnections)
        .onReceive(NotificationCenter.default.publisher(for: .velodropCheckForUpdates)) { _ in
            section = .general
            checkForUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .velodropOpenBrowserSettings)) { _ in
            section = .browsers
            refreshConnections()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if section == .browsers { refreshConnections() }
        }
        .onChange(of: model.testingBrowser) { refreshConnections() }
        .sheet(item: $setupBrowser) { browser in browserSetup(browser) }
        .confirmationDialog("Disconnect Browser?", isPresented: Binding(
            get: { disconnectConfirmation != nil },
            set: { if !$0 { disconnectConfirmation = nil } }
        ), presenting: disconnectConfirmation) { browser in
            Button("Disconnect", role: .destructive) { disconnect(browser) }
        } message: { browser in
            Text("VeloDrop will stop receiving downloads from \(browser.name).")
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
            browserConnectors

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

        }
    }

    private var browserConnectors: some View {
        settingsCard("Browser Extensions", symbol: "puzzlepiece.extension") {
            VStack(spacing: 0) {
                let browsers = SupportedBrowser.supported.sorted { $0.isInstalled && !$1.isInstalled }
                ForEach(browsers) { browser in
                    if browser.id != browsers.first?.id {
                        Divider().overlay(VD.hairline).padding(.leading, 42)
                    }
                    browserRow(browser)
                }
                .id(browserSetupVersion)
            }
        }
    }

    private func browserRow(_ browser: SupportedBrowser) -> some View {
        let connection = connections[browser.id]
        let ready = connection?.extensionVersion == currentVersion
        let passed = verified[browser.id].flatMap { $0.extensionVersion == currentVersion ? $0.checkedAt : nil }
        let registered = browser.isRegistered
        let runningTest = model.testingBrowser == browser.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Group {
                    if let icon = browser.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 25, height: 25)
                .opacity(browser.isInstalled ? 1 : 0.42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(browser.name)
                        .font(.system(size: 12, weight: .semibold))
                    if !browser.isInstalled {
                        Text("Not installed").foregroundStyle(.secondary)
                    } else if runningTest {
                        Label("Testing download…", systemImage: "arrow.down.circle").foregroundStyle(VD.accent)
                    } else if registered, ready, let passed {
                        Label("Test passed \(Format.when(passed))", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(VD.green)
                    } else if registered, ready, let connection {
                        Label("Last connected \(Format.when(connection.checkedAt))", systemImage: "link")
                            .foregroundStyle(VD.green)
                    } else if registered, let version = connection?.extensionVersion {
                        Text("Extension \(version) needs updating").foregroundStyle(VD.orange)
                    } else {
                        Text(registered ? "Waiting for extension" : "Connector not set up").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10.5))
                Spacer(minLength: 8)
                if browser.isInstalled {
                    if registered, ready {
                        if runningTest {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Test Download") { model.testBrowser(browser) }
                                .buttonStyle(VDSecondaryButtonStyle(compact: true))
                                .disabled(model.testingBrowser != nil)
                        }
                    } else {
                        Button(registered ? "Extension Setup…" : "Connect…") { setupBrowser = browser }
                            .buttonStyle(VDPrimaryButtonStyle(compact: true))
                    }
                    if registered {
                        Menu {
                            if ready { Button("Extension Setup…") { setupBrowser = browser } }
                            Button("Disconnect…") { disconnectConfirmation = browser }
                                .disabled(runningTest)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More actions for \(browser.name)")
                    }
                }
            }
            if let error = model.browserTestErrors[browser.id], registered {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VD.orange)
                    .padding(.leading, 35)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
    }

    private func browserSetup(_ browser: SupportedBrowser) -> some View {
        let signed = browser.family == .firefox ? signedFirefoxExtension : nil
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = browser.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect \(browser.name)").font(.title3.weight(.semibold))
                    Text(setupSubtitle(browser, signed: signed != nil))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if signed == nil {
                Text(browser.family == .firefox
                    ? "Choose Load Temporary Add-on and paste the manifest path with ⇧⌘G. The extension is removed when Firefox quits."
                    : "Turn on Developer mode, choose Load unpacked, then press ⇧⌘G to paste the extension folder. If VeloDrop is already listed, choose Reload instead.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vdCard(padding: 12)
            }
            if let setupError {
                Label(setupError, systemImage: "exclamationmark.circle")
                    .foregroundStyle(VD.orange).font(.caption)
            }
            Divider()
            HStack {
                Button("Close") { setupBrowser = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(signed == nil ? "Copy Path and Open Browser" : "Open Signed Extension") {
                    install(browser, signed: signed)
                }
                .buttonStyle(VDPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
        .onAppear { setupError = nil }
    }

    private func setupSubtitle(_ browser: SupportedBrowser, signed: Bool) -> LocalizedStringKey {
        if signed { return "Open the signed extension in Firefox and confirm installation." }
        if browser.family == .firefox { return "Load the VeloDrop manifest from This Firefox." }
        return "Load or refresh VeloDrop in your browser’s extension manager."
    }

    private func install(_ browser: SupportedBrowser, signed: URL?) {
        do {
            guard try BrowserConnector.register(browser, bundle: Bundle.main.bundleURL) else { return }
            browserSetupVersion += 1
            setupBrowser = nil
            if let signed {
                browser.open(signed)
            } else {
                let clipboard = NSPasteboard.general
                clipboard.clearContents()
                clipboard.setString(browser.extensionSelectionPath(in: Bundle.main.bundleURL), forType: .string)
                browser.openInstallPage()
            }
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func disconnect(_ browser: SupportedBrowser) {
        do {
            try BrowserConnector.remove(browser)
            model.workspace.removeBrowserConnection(browser.id)
            browserSetupVersion += 1
            refreshConnections()
        } catch {
            message = error.localizedDescription
            self.error = true
        }
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

    private func refreshConnections() {
        connections = Dictionary(uniqueKeysWithValues: BrowserID.allCases.compactMap { id in
            model.workspace.browserConnection(id).map { (id, $0) }
        })
        verified = Dictionary(uniqueKeysWithValues: BrowserID.allCases.compactMap { id in
            model.workspace.browserTestResult(id).map { (id, $0) }
        })
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

}
