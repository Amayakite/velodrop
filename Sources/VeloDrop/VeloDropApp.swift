import AppKit
import SwiftUI
import VeloCore

@main
struct VeloDropApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…", action: lifecycle.openPreferences).keyboardShortcut(",")
                }
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…", action: lifecycle.openUpdates)
                }
                CommandGroup(after: .windowArrangement) {
                    Button("Downloads", action: lifecycle.openDownloads)
                }
            }

    }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = DownloadModel()
    private var statusItem: NSStatusItem?
    private weak var foregroundWindow: NSWindow?
    private var downloadsWindow: NSWindow?

    private func updateStatusItem() {
        withObservationTracking {
            statusItem?.button?.image = NSImage(systemSymbolName: model.activeCount > 0
                ? "arrow.down.circle.fill" : "arrow.down.circle", accessibilityDescription: "VeloDrop")
            statusItem?.button?.toolTip = "VeloDrop · " + Format.rate(model.rate)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
    }

    @objc private func statusItemClicked() {
        if let confirmationWindow { present(confirmationWindow) }
        else { openDownloads() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let foregroundWindow, foregroundWindow.isVisible { foregroundWindow.makeKeyAndOrderFront(nil) }
    }

    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var confirmationWindow: NSWindow?
    private var confirmingID: UUID?
    private var confirmationUpdatePending = false
    private var progressWindows: [UUID: NSWindow] = [:]

    private func scheduleConfirmationUpdate() {
        guard !confirmationUpdatePending else { return }
        confirmationUpdatePending = true
        // Finish the current button/keyboard event before moving key-window focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.confirmationUpdatePending = false
            self.updateConfirmationWindow()
        }
    }

    private func updateConfirmationWindow() {
        if let window = confirmationWindow, confirmingID == model.confirmation?.id {
            present(window)
            return
        }
        if let previous = confirmationWindow {
            previous.makeFirstResponder(nil)
            if foregroundWindow === previous { foregroundWindow = nil }
            confirmationWindow = nil
            previous.close()
        }
        confirmingID = model.confirmation?.id
        confirmationWindow = nil
        guard let item = model.confirmation else { return }
        confirmationWindow = makeWindow(title: String(localized: "Confirm Download")) {
            DownloadConfirmationView(transfer: item, model: model).id(item.id)
        }
        confirmationWindow?.titleVisibility = .hidden
        confirmationWindow?.titlebarAppearsTransparent = true
        present(confirmationWindow)
    }

    func openProgress(_ id: UUID) {
        if progressWindows[id] == nil {
            let window = makeWindow(title: String(localized: "Download Progress")) {
                DownloadProgressView(id: id, model: model)
            }
            // Stack simultaneous progress windows instead of hiding them
            // exactly under each other.
            let step = CGFloat(progressWindows.count % 5) * 26
            window.setFrameOrigin(NSPoint(x: window.frame.origin.x + step,
                                          y: window.frame.origin.y - step))
            progressWindows[id] = window
        }
        present(progressWindows[id])
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === confirmationWindow {
            if let item = model.confirmation, item.id == confirmingID { model.cancel(item) }
            return false
        }
        return true
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        if model.duplicateInstance {
            let identifier = Bundle.main.bundleIdentifier ?? BundleLayout.identifier
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                .activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openSettingsFromBridge),
            name: Notification.Name("com.amayakite.velodrop.openSettings"), object: nil)
        let settingsRequest = workspaceOpenSettingsRequest()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        updateStatusItem()
        let background = ProcessInfo.processInfo.environment["VELODROP_BACKGROUND_LAUNCH"] == "1"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.onConfirmationChanged = { [weak self] in self?.scheduleConfirmationUpdate() }
            self.model.onProgress = { [weak self] id in self?.openProgress(id) }
            self.model.onBrowserIntake = { [weak self] in
                guard let self else { return }
                if self.model.confirmation != nil { self.scheduleConfirmationUpdate() }
                else { self.openDownloads() }
            }
            if self.model.confirmation != nil { self.scheduleConfirmationUpdate() }
            self.model.showPendingIntake()
            if settingsRequest {
                self.openDownloads()
                self.openBrowserPreferences()
            } else if !background && self.model.confirmation == nil {
                self.openDownloads()
                if !UserDefaults.standard.bool(forKey: "welcomeCompleted") { self.openWelcome() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let confirmationWindow { present(confirmationWindow) }
        else { openDownloads() }
        return false
    }

    @objc private func openSettingsFromBridge() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The bridge only writes the flag when the app is not running; a
            // running app can receive a stale one after an interrupted launch.
            try? FileManager.default.removeItem(
                at: self.model.workspace.root.appendingPathComponent("open-settings"))
            self.openBrowserPreferences()
        }
    }

    private func workspaceOpenSettingsRequest() -> Bool {
        let flag = model.workspace.root.appendingPathComponent("open-settings")
        guard FileManager.default.fileExists(atPath: flag.path) else { return false }
        try? FileManager.default.removeItem(at: flag)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        model.shutdown()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        progressWindows = progressWindows.filter { $0.value !== window }
        if window === downloadsWindow { downloadsWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
        if window === welcomeWindow { welcomeWindow = nil }
    }

    func openWelcome() {
        if welcomeWindow == nil {
            welcomeWindow = makeWindow(title: "VeloDrop") {
                WelcomeView(model: model, openBrowserPreferences: openBrowserPreferences) { [weak self] in
                    UserDefaults.standard.set(true, forKey: "welcomeCompleted")
                    self?.welcomeWindow?.close()
                    self?.openDownloads()
                }
            }
            welcomeWindow?.titleVisibility = .hidden
            welcomeWindow?.titlebarAppearsTransparent = true
        }
        present(welcomeWindow)
    }

    func openUpdates() {
        openPreferences()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .velodropCheckForUpdates, object: nil)
        }
    }

    func openPreferences() {
        openPreferences(showBrowsers: false)
    }

    private func openBrowserPreferences() {
        openPreferences(showBrowsers: true)
    }

    private func openPreferences(showBrowsers: Bool) {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: String(localized: "VeloDrop Settings")) {
                PreferencesView(model: model, showBrowsers: showBrowsers)
            }
        } else if showBrowsers {
            NotificationCenter.default.post(name: .velodropOpenBrowserSettings, object: nil)
        }
        present(settingsWindow)
    }

    func openDownloads() {
        if downloadsWindow == nil {
            downloadsWindow = makeWindow(title: "VeloDrop",
                                         contentSize: NSSize(width: 1100, height: 728)) {
                DownloadsPanel(model: model, openPreferences: openPreferences, openBrowserPreferences: openBrowserPreferences)
                    .frame(minWidth: 820, minHeight: 540)
            }
            downloadsWindow?.styleMask.insert([.resizable, .fullSizeContentView])
            downloadsWindow?.titleVisibility = .hidden
            downloadsWindow?.titlebarAppearsTransparent = true
            downloadsWindow?.contentMinSize = NSSize(width: 820, height: 540)
        }
        present(downloadsWindow)
    }

    private func makeWindow<Content: View>(title: String, contentSize: NSSize? = nil,
                                          @ViewBuilder content: () -> Content) -> NSWindow {
        let hosting = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: hosting)

        // SwiftUI does not have a usable fitting size until its hosting view has been
        // laid out. Sizing and centering the window before that happens leaves a
        // one-point window pinned to the top-right corner of the screen.
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize
        if let contentSize {
            window.setContentSize(contentSize)
        } else if fitted.width > 1, fitted.height > 1 {
            window.setContentSize(fitted)
        }

        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        center(window, on: activeScreen())
        return window
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func center(_ window: NSWindow, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        window.setFrameOrigin(origin)
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        foregroundWindow = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Browser capture explicitly requests a foreground dialog, including repeated
        // handoffs after Edge became active again.
        NSApp.activate(ignoringOtherApps: true)
    }
}
