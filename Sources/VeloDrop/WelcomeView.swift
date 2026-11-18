import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Bindable var model: DownloadModel
    let openPreferences: () -> Void
    let done: () -> Void
    @State private var step = 0
    @State private var choosingFolder = false
    @State private var connection: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Welcome to VeloDrop", systemImage: "arrow.down.circle.fill")
                .font(.title.weight(.semibold))
            if step == 0 {
                Text("Choose where your downloads are saved.").font(.headline)
                Text(model.defaultFolder).textSelection(.enabled)
                Button("Choose Folder…") { choosingFolder = true }
                Text("You can change the filename and destination before each browser download.")
                    .foregroundStyle(.secondary)
            } else if step == 1 {
                Text("Connect Microsoft Edge").font(.headline)
                Text("Open Settings, select Microsoft Edge, and follow the extension setup steps.")
                Button("Settings…", action: openPreferences)
                Text("Open the VeloDrop extension in Edge, then check the connection here.")
                    .foregroundStyle(.secondary)
                Button("Check Connection") { connection = model.lastBrowserConnection }
                if let connection {
                    Label("Last connected \(connection.formatted(date: .omitted, time: .standard))", systemImage: "checkmark.circle")
                }
            } else {
                Text("Try your first download").font(.headline)
                Text("Download a file in Edge. VeloDrop will ask whether to download here, use Edge, or cancel.")
                Button("Test Download in Edge") {
                    guard let edge = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.edgemac"),
                          let url = URL(string: "https://speed.cloudflare.com/__down?bytes=3145728") else { return }
                    NSWorkspace.shared.open([url], withApplicationAt: edge, configuration: NSWorkspace.OpenConfiguration())
                }
                Text("The test downloads a 3 MiB file from Cloudflare. Your browser rules still apply.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("You can also paste several links into Add Downloads, or drag a link into the main window.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            HStack {
                Button("Set Up Later", action: done)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 2 ? "Done" : "Continue") {
                    if step < 2 { step += 1 } else { done() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500, height: 340)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let directory) = result { model.defaultFolder = directory.path }
        }
    }
}
