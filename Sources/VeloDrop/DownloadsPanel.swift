import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeloCore

private let accent = Color(red: 0.21, green: 0.39, blue: 0.93)

struct DownloadsPanel: View {
    @Bindable var model: DownloadModel
    var inWindow = false
    let openPreferences: () -> Void
    let openDownloads: () -> Void
    @State private var search = ""
    @State private var confirmClear = false
    @State private var selected = Set<UUID>()
    @State private var deleting = Set<UUID>()
    @State private var showDelete = false
    @State private var showLink = false
    @State private var link = ""
    @State private var formError: String?
    @State private var scope: Scope = .all
    @FocusState private var linkFocused: Bool

    private enum Scope: String, CaseIterable { case all = "All", current = "In progress", history = "Finished" }

    private var visible: [Transfer] {
        model.transfers.filter { item in
            if scope == .current && item.state.terminal { return false }
            if scope == .history && !item.state.terminal { return false }
            return search.isEmpty || item.displayName.localizedStandardContains(search)
                || item.sourceURL?.host?.localizedStandardContains(search) == true
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
                if inWindow {
                    TextField("Search Downloads", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
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
                        ForEach(visible) { transfer in
                            HStack {
                                if inWindow {
                                    Toggle("Select download", isOn: Binding(
                                        get: { selected.contains(transfer.id) },
                                        set: { if $0 { selected.insert(transfer.id) } else { selected.remove(transfer.id) } }
                                    )).labelsHidden().toggleStyle(.checkbox)
                                }
                                TransferRow(transfer: transfer, model: model,
                                            showDetails: { model.onProgress?(transfer.id) },
                                            confirmDownload: { model.askToConfirm(transfer) },
                                            deleteDownload: {
                                                deleting = [transfer.id]
                                                showDelete = true
                                            })
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .frame(height: inWindow ? nil : min(CGFloat(visible.count) * 73 + 10, 324))
                .accessibilityLabel("Download list")
            }
            if inWindow && !visible.isEmpty {
                HStack {
                    Button("Select All") { selected = Set(visible.map(\.id)) }
                    Button("Deselect All") { selected.removeAll() }
                    Spacer()
                    Button("Delete Selected…", systemImage: "trash") {
                        deleting = selected
                        showDelete = true
                    }.tint(.red).disabled(selected.isEmpty)
                }.padding(12)
            }
            Divider()
            footer
        }
        .frame(width: inWindow ? 538 : 400)
        .tint(accent)
        .alert("Delete Downloads?", isPresented: $showDelete) {
            Button("Delete Files and History", role: .destructive) {
                let ids = deleting
                selected.subtract(ids)
                Task { await model.delete(ids, files: true) }
            }
            Button("Delete History Only") {
                let ids = deleting
                selected.subtract(ids)
                Task { await model.delete(ids, files: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files will be moved to Trash. Active downloads will be stopped.")
        }
        .alert("Clear Finished History?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                for transfer in model.transfers where transfer.state.terminal {
                    model.removeHistory(transfer)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded files will stay on disk.")
        }
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
        if !search.isEmpty { return "No matching downloads" }
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
                if model.transfers.contains(where: { $0.state.terminal }) {
                    Button("Clear Finished History…") { confirmClear = true }
                    Divider()
                }
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
    let showDetails: () -> Void
    let confirmDownload: () -> Void
    let deleteDownload: () -> Void
    @State private var confirmTrash = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(transfer.state == .failed ? .orange : accent)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 32, height: 36)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Button(action: showDetails) {
                    Text(transfer.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(transfer.displayName)
                if !transfer.state.terminal && transfer.state != .awaitingConfirmation {
                    ProgressView(value: transfer.fraction ?? 0)
                        .controlSize(.small)
                        .accessibilityLabel("Download progress")
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1)
                    .help(detail)
            }
            Spacer(minLength: 4)
            if transfer.state == .awaitingConfirmation {
                Button("Confirm…", action: confirmDownload)
                    .controlSize(.small)
            } else if transfer.state.running {
                icon("pause.fill", "Pause") { model.pause(transfer) }
            } else if transfer.state == .paused || (transfer.state == .failed && transfer.url != nil) {
                icon("play.fill", transfer.state == .paused ? "Resume" : "Retry") { model.resume(transfer) }
            } else if transfer.state == .completed {
                icon("folder", "Show in Finder") { model.reveal(transfer) }
            }
            Button(action: deleteDownload) {
                Image(systemName: "trash").foregroundStyle(.red)
            }.buttonStyle(.borderless).help("Delete Downloads?")

            Menu {
                Button("Download Details", action: showDetails)
                if !transfer.state.terminal {
                    if transfer.fromBrowser {
                        Button("Continue in Edge") { model.useEdge(transfer) }
                    }
                    Button("Cancel download", role: .destructive) { model.cancel(transfer) }
                } else {
                    if transfer.state == .completed {
                        Button("Open File") { model.openFile(transfer) }
                        Button("Show in Finder") { model.reveal(transfer) }
                        Button("Move File to Trash…", role: .destructive) { confirmTrash = true }
                    }
                    Button("Delete Downloads?", role: .destructive, action: deleteDownload)
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
        .alert("Move Download to Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trash(transfer) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(transfer.displayName)
        }
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
        case .awaitingConfirmation: return String(localized: "Waiting for confirmation")
        case .queued: return String(localized: "Waiting")
        case .downloading, .paused:
            let done = Format.bytes(transfer.received)
            let size = transfer.total > 0 ? String(localized: "\(done) of \(Format.bytes(transfer.total))") : done
            return transfer.state == .paused ? String(localized: "Paused · \(size)") : "\(size) · \(Format.rate(transfer.speed))"
        case .completed:
            let size = String(localized: "Downloaded · \(Format.bytes(transfer.received))")
            let date = (transfer.finishedAt ?? transfer.updatedAt).formatted(date: .abbreviated, time: .shortened)
            return [size, transfer.sourceURL?.host, date].compactMap { $0 }.joined(separator: " · ")
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
