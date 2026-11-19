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
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                BrandMark(size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to VeloDrop")
                        .font(.system(size: 22, weight: .bold))
                    Text("A faster, friendlier download manager for your Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set Up Later", action: done)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 18)

            stepIndicator
                .padding(.horizontal, 26)
                .padding(.bottom, 14)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(VD.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(VD.hairline, lineWidth: 0.8)
                    )
                stepContent
                    .padding(22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 26)
            .frame(height: 190)

            HStack(spacing: 8) {
                Text("\(step + 1) of 3")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
                if step > 0 {
                    Button("Back") { withAnimation(.easeOut(duration: 0.18)) { step -= 1 } }
                        .buttonStyle(VDSecondaryButtonStyle())
                }
                Button(step == 2 ? "Done" : "Continue") {
                    if step < 2 { withAnimation(.easeOut(duration: 0.18)) { step += 1 } }
                    else { done() }
                }
                .buttonStyle(VDPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let directory) = result { model.defaultFolder = directory.path }
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 7) {
            ForEach(0..<3) { index in
                Capsule()
                    .fill(index <= step ? AnyShapeStyle(VD.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.09)))
                    .frame(height: 3)
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 9) {
                Label("Choose where your downloads are saved.", systemImage: "folder.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("You can change the filename and destination before each browser download.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(VD.accent)
                        .font(.system(size: 12))
                    Text(model.defaultFolder)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Choose Folder…") { choosingFolder = true }
                        .buttonStyle(VDSecondaryButtonStyle(compact: true))
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(VD.hairline, lineWidth: 0.8)
                )
            }
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                Label("Connect Microsoft Edge", systemImage: "puzzlepiece.extension")
                    .font(.system(size: 14, weight: .semibold))
                Text("Open Settings, select Microsoft Edge, and follow the extension setup steps.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Settings…", action: openPreferences)
                        .buttonStyle(VDPrimaryButtonStyle(compact: true))
                    Button("Check Connection") { connection = model.lastBrowserConnection }
                        .buttonStyle(VDSecondaryButtonStyle(compact: true))
                    Spacer()
                }
                if let connection {
                    Label("Last connected \(Format.time(connection))",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(VD.green)
                } else {
                    Text("Open the VeloDrop extension in Edge, then check the connection here.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                Label("Try your first download", systemImage: "arrow.down.circle")
                    .font(.system(size: 14, weight: .semibold))
                Text("Download a file in Edge. VeloDrop will ask whether to download here, use Edge, or cancel.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Button("Test Download in Edge") {
                    guard let edge = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.edgemac"),
                          let url = URL(string: "https://speed.cloudflare.com/__down?bytes=3145728") else { return }
                    NSWorkspace.shared.open([url], withApplicationAt: edge, configuration: NSWorkspace.OpenConfiguration())
                }
                .buttonStyle(VDPrimaryButtonStyle(compact: true))
                Text("The test downloads a 3 MiB file from Cloudflare. Your browser rules still apply.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
