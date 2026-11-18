import AppKit
import SwiftUI
import VeloCore

@main
struct VeloDropApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @State private var model = DownloadModel()

    var body: some Scene {
        MenuBarExtra {
            DownloadsPanel(model: model)
                .onAppear { lifecycle.model = model }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                if model.activeCount > 0 {
                    Text(Format.rate(model.rate)).monospacedDigit()
                }
            }
            .accessibilityLabel(model.activeCount > 0 ? "VeloDrop, \(model.activeCount) active" : "VeloDrop")
            .task { lifecycle.model = model }
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView(model: model)
                .frame(width: 460)
        }
    }
}

final class AppLifecycle: NSObject, NSApplicationDelegate {
    weak var model: DownloadModel?
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file)
    }

    static func rate(_ value: Int64) -> String {
        value > 0 ? bytes(value) + "/s" : "0 KB/s"
    }
}
