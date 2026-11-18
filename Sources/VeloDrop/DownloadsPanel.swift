import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeloCore

private let accent = Color(red: 0.21, green: 0.39, blue: 0.93)

struct DownloadsPanel: View {
    let model: DownloadModel
    var inWindow = false
    let openPreferences: () -> Void
    @State private var showLink = false
    @State private var link = ""
    @State private var formError: String?
    @State private var scope: Scope = .all
    @FocusState private var linkFocused: Bool

    private enum Scope: String, CaseIterable { case all = "All", current = "In progress", history = "Finished" }

    private var visible: [Transfer] {
        switch scope {
        case .all: return model.transfers
        case .current: return model.transfers.filter { !$0.state.terminal }
        case .history: return model.transfers.filter { $0.state.terminal }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showLink { linkForm }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if !model.transfers.isEmpty {
                Picker("Downloads", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            if visible.isEmpty { empty }
            else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(visible) { TransferRow(transfer: $0, model: model) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .frame(height: inWindow ? nil : min(CGFloat(visible.count) * 73 + 10, 324))
                .accessibilityLabel("Download list")
            }
            Divider()
            footer
        }
        .frame(width: inWindow ? 408 : 382)
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(colors: [Color(red: 0.31, green: 0.58, blue: 1), accent],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Downloads").font(.system(size: 16, weight: .semibold))
                if model.activeCount > 0 {
                    Text("\(model.activeCount) active · \(Format.rate(model.rate))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("VeloDrop").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button {
                showLink.toggle()
                if showLink {
                    linkFocused = true
                    formError = nil
                }
            } label: {
                Image(systemName: showLink ? "xmark" : "plus").frame(width: 16, height: 17)
            }
            .help(showLink ? "Close link entry" : "Add download link")
            .accessibilityLabel(showLink ? "Close link entry" : "Add download link")
        }
        .padding(16)
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                TextField("https://example.com/file.zip", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .focused($linkFocused)
                    .onSubmit(addLink)
                    .accessibilityLabel("Download URL")
                Button("Add", action: addLink)
                    .buttonStyle(.borderedProminent)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let formError {
                Text(formError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text(emptyTitle)
                .font(.subheadline.weight(.medium))
            if model.transfers.isEmpty {
                Text("Add a link or download a file from Edge.")
                    .font(.caption).foregroundStyle(.secondary)
                if inWindow {
                    Button("Edge Settings…", action: openPreferences)
                        .padding(.top, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: inWindow ? .infinity : nil)
        .padding(.vertical, 20)
        .padding(.bottom, 5)
    }

    private var emptyTitle: LocalizedStringKey {
        if model.transfers.isEmpty { return "No downloads yet" }
        return scope == .history ? "No finished downloads" : "No active downloads"
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(model.workspace.destination)
            } label: {
                Label("Downloads folder", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            Button(action: openPreferences) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            .foregroundStyle(.secondary)
            Menu {
                Button("Quit VeloDrop") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func addLink() {
        do {
            try model.add(link)
            link = ""
            formError = nil
            showLink = false
            scope = .all
        } catch {
            formError = error.localizedDescription
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let model: DownloadModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(transfer.state == .failed ? .orange : accent)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 32, height: 36)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(transfer.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(transfer.name)
                if !transfer.state.terminal {
                    ProgressView(value: transfer.fraction ?? 0)
                        .controlSize(.small)
                        .accessibilityLabel("Download progress")
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1)
                    .help(detail)
            }
            Spacer(minLength: 4)
            if transfer.state.running {
                icon("pause.fill", "Pause") { model.pause(transfer) }
            } else if transfer.state == .paused || (transfer.state == .failed && transfer.url != nil) {
                icon("play.fill", transfer.state == .paused ? "Resume" : "Retry") { model.resume(transfer) }
            } else if transfer.state == .completed {
                icon("folder", "Show in Finder") { model.reveal(transfer) }
            }
            Menu {
                if !transfer.state.terminal {
                    if transfer.fromBrowser {
                        Button("Continue in Edge") { model.useEdge(transfer) }
                    }
                    Button("Cancel download", role: .destructive) { model.cancel(transfer) }
                } else {
                    if transfer.state == .completed { Button("Show in Finder") { model.reveal(transfer) } }
                    Button("Remove from history") { model.removeHistory(transfer) }
                        .disabled(transfer.fromBrowser && Date().timeIntervalSince(transfer.updatedAt) <= 120)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(transfer.name)")
        }
        .padding(8)
        .frame(height: 66)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        if transfer.state == .failed { return "exclamationmark.circle" }
        guard let type = UTType(filenameExtension: (transfer.name as NSString).pathExtension) else {
            return "doc"
        }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .diskImage) { return "opticaldisc" }
        return "doc"
    }

    private var detail: String {
        switch transfer.state {
        case .queued: return String(localized: "Waiting")
        case .downloading, .paused:
            let done = Format.bytes(transfer.received)
            let size = transfer.total > 0 ? String(localized: "\(done) of \(Format.bytes(transfer.total))") : done
            return transfer.state == .paused ? String(localized: "Paused · \(size)") : "\(size) · \(Format.rate(transfer.speed))"
        case .completed: return String(localized: "Downloaded · \(Format.bytes(transfer.received))")
        case .failed: return transfer.message ?? String(localized: "Download failed")
        case .canceled: return String(localized: "Canceled")
        }
    }

    private func icon(_ symbol: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}
