import AppKit
import SwiftUI
import VeloCore

@main
struct VeloDropApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    private var model: DownloadModel { lifecycle.model }

    var body: some Scene {
        MenuBarExtra {
            DownloadsPanel(model: model, openPreferences: lifecycle.openPreferences, openDownloads: lifecycle.openDownloads)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                if model.activeCount > 0 {
                    Text(Format.rate(model.rate)).monospacedDigit()
                }
            }
            .accessibilityLabel(model.activeCount > 0
                                ? String(localized: "VeloDrop, \(model.activeCount) active") : "VeloDrop")
        }
        .menuBarExtraStyle(.window)

    }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = DownloadModel()
    private var downloadsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var confirmationWindow: NSWindow?
    private var confirmingID: UUID?
    private var progressWindows: [UUID: NSWindow] = [:]

    func showConfirmation() {
        if let window = confirmationWindow, confirmingID == model.confirmation?.id {
            present(window)
            return
        }
        confirmingID = model.confirmation?.id
        confirmationWindow?.orderOut(nil)
        confirmationWindow = nil
        guard let item = model.confirmation else {
            DispatchQueue.main.async { [weak self] in self?.model.confirmNextIfNeeded() }
            return
        }
        confirmationWindow = makeWindow(title: String(localized: "Confirm Download")) {
            DownloadConfirmationView(transfer: item, model: model)
        }
        present(confirmationWindow)
    }

    func openProgress(_ id: UUID) {
        if progressWindows[id] == nil {
            progressWindows[id] = makeWindow(title: String(localized: "Download Progress")) {
                DownloadProgressView(id: id, model: model)
            }
        }
        present(progressWindows[id])
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === confirmationWindow, let item = model.confirmation {
            model.useEdge(item)
            return false
        }
        return true
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        let background = ProcessInfo.processInfo.environment["VELODROP_BACKGROUND_LAUNCH"] == "1"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.onConfirmationChanged = { [weak self] in self?.showConfirmation() }
            self.model.onProgress = { [weak self] id in self?.openProgress(id) }
            self.model.onBrowserIntake = { [weak self] in
                guard let self else { return }
                if self.model.confirmation != nil { self.showConfirmation() }
                else { self.openDownloads() }
            }
            self.model.confirmNextIfNeeded()
            if self.model.confirmation != nil { self.showConfirmation() }
            self.model.showPendingIntake()
            if !background && self.model.confirmation == nil { self.openDownloads() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDownloads()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        progressWindows = progressWindows.filter { $0.value !== window }
        if window === downloadsWindow { downloadsWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
    }

    func openPreferences() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: String(localized: "VeloDrop Settings")) {
                PreferencesView(model: model)
                    .frame(width: 480, height: 430)
            }
        }
        present(settingsWindow)
    }

    func openDownloads() {
        if downloadsWindow == nil {
            downloadsWindow = makeWindow(title: "VeloDrop") {
                DownloadsPanel(model: model, inWindow: true, openPreferences: openPreferences, openDownloads: openDownloads)
                    .frame(height: 480)
            }
        }
        present(downloadsWindow)
    }

    private func makeWindow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file)
    }

    static func rate(_ value: Int64) -> String {
        value > 0 ? bytes(value) + "/s" : "0 KB/s"
    }
}
