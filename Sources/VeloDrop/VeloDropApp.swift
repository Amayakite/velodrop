import AppKit
import SwiftUI
import VeloCore

@main
struct VeloDropApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    private var model: DownloadModel { lifecycle.model }

    var body: some Scene {
        MenuBarExtra {
            DownloadsPanel(model: model, openPreferences: lifecycle.openPreferences)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["VELODROP_BACKGROUND_LAUNCH"] != "1" else { return }
        DispatchQueue.main.async { [weak self] in self?.openDownloads() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDownloads()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === downloadsWindow { downloadsWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
    }

    func openPreferences() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: String(localized: "VeloDrop Settings")) {
                PreferencesView(model: model)
                    .frame(width: 460, height: 360)
            }
        }
        present(settingsWindow)
    }

    private func openDownloads() {
        if downloadsWindow == nil {
            downloadsWindow = makeWindow(title: "VeloDrop") {
                DownloadsPanel(model: model, inWindow: true, openPreferences: openPreferences)
                    .frame(height: 400)
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
