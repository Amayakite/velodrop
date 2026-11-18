import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeloCore

struct DownloadsPanel: View {
    @Bindable var model: DownloadModel
    var inWindow = true
    let openPreferences: () -> Void
    let openDownloads: () -> Void
    @State private var search = ""
    @State private var selected = Set<UUID>()
    @State private var deletion: DownloadDeletion?
    @State private var showLink = false
    @State private var scope: DownloadScope = .all
    @State private var fileKind = "All Types"
    @State private var sidebar = true
    @State private var inspector = false
    @State private var sortOrder = [KeyPathComparator(\Transfer.createdAt, order: .reverse)]

    private var visible: [Transfer] {
        model.transfers.filter { scope.includes($0) && matchesType($0) && (search.isEmpty ||
            $0.displayName.localizedStandardContains(search) ||
            $0.sourceURL?.host?.localizedStandardContains(search) == true)
        }.sorted(using: sortOrder)
    }
    private var selection: [Transfer] { model.transfers.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack {
                Text(scope.title).font(.headline)
                Spacer()
                Picker("File Type", selection: $fileKind) {
                    ForEach(["All Types", "Documents", "Images", "Video", "Archives"], id: \.self) { kind in
                        Text(LocalizedStringKey(kind)).tag(kind)
                    }
                }.frame(width: 180)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            GeometryReader { geometry in
            HStack(spacing: 0) {
                if sidebar && (!inspector || geometry.size.width >= 950) {
                    List(DownloadScope.allCases, selection: $scope) { category in
                        HStack {
                            Label(category.title, systemImage: category.symbol)
                            Spacer()
                            Text(String(model.transfers.filter(category.includes).count))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }.tag(category)
                    }
                    .listStyle(.sidebar).frame(width: 180)
                    Divider()
                }
                VStack(spacing: 0) {
                    if let notice = model.notice {
                        HStack {
                            Label(notice, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            Spacer()
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).help("Dismiss")
                        }.padding(10)
                    }
                    table
                }.frame(minWidth: 0, maxWidth: .infinity)
                if inspector {
                    Divider()
                    ScrollView {
                        if selection.count == 1, let item = selection.first {
                            TransferInspector(transfer: item, model: model)
                        } else {
                            Text("Select a download to see its details.")
                                .foregroundStyle(.secondary).padding(20)
                        }
                    }.frame(width: 260)
                }
            }
            }
            Divider()
            HStack {
                Text("\(visible.count) downloads").foregroundStyle(.secondary)
                if !selected.isEmpty { Text("\(selected.count) selected").foregroundStyle(.secondary) }
                Spacer()
                Label(Format.rate(model.rate), systemImage: "arrow.down").monospacedDigit()
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: model.defaultFolder)) } label: {
                    Image(systemName: "folder")
                }.help("Downloads folder").buttonStyle(.borderless)
            }.font(.caption).padding(.horizontal, 14).padding(.vertical, 9)
        }
        .sheet(isPresented: $showLink) { AddDownloadsView(model: model) }
        .sheet(item: $deletion) { request in DeleteDownloadsView(ids: request.ids, model: model) }
        .onChange(of: model.transfers.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .onChange(of: scope) { selected.removeAll() }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy(Transfer.supports) else { return false }
            do { try model.addLinks(urls.map(\.absoluteString).joined(separator: "\n")); return true }
            catch { model.notice = error.localizedDescription; return false }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                if inspector { inspector = false; sidebar = true }
                else { sidebar.toggle() }
            } label: { Image(systemName: "sidebar.left") }.help("Toggle Sidebar")
            Button { showLink = true } label: { Label("Add", systemImage: "plus") }.keyboardShortcut("n")
            Divider().frame(height: 18)
            Button { selection.filter { $0.state.running }.forEach(model.pause) } label: {
                Image(systemName: "pause")
            }.disabled(!selection.contains { $0.state.running }).help("Pause")
            Button { selection.filter { $0.state == .paused || ($0.state == .failed && $0.url != nil) }.forEach(model.resume) } label: {
                Image(systemName: "play")
            }.disabled(!selection.contains { $0.state == .paused || ($0.state == .failed && $0.url != nil) }).help("Resume")
            Button(role: .destructive) { delete(selected) } label: {
                Label("Delete", systemImage: "trash").foregroundStyle(selected.isEmpty ? Color.secondary : .red)
            }.disabled(selected.isEmpty).keyboardShortcut(.delete, modifiers: .command)
            Spacer(minLength: 10)
            TextField("Search Downloads", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            Button { inspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Download Details")
            Button(action: openPreferences) { Image(systemName: "gearshape") }.help("Settings")
        }.buttonStyle(.borderless).padding(14)
    }

    private var table: some View {
        Table(visible, selection: $selected, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.displayName) { item in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.displayName as NSString).pathExtension) ?? .data))
                        .resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayName).lineLimit(1).truncationMode(.middle)
                        if item.state.running { ProgressView(value: item.fraction ?? 0).controlSize(.mini) }
                    }
                }.padding(.vertical, 5).help(item.displayName)
            }.width(min: 160, ideal: 220, max: .infinity)
            TableColumn("Status", value: \.statusText) { item in
                Text(item.statusText).foregroundStyle(item.state == .failed ? Color.orange : .secondary)
            }.width(min: 90, ideal: 100, max: 115)
            TableColumn("Size", value: \.total) { item in
                Text(item.total > 0 ? Format.bytes(item.total) : "—").monospacedDigit()
            }.width(min: 60, ideal: 70, max: 85)
            TableColumn("Speed", value: \.speed) { item in
                Text(item.state.running ? Format.rate(item.speed) : "—").monospacedDigit()
            }.width(min: 65, ideal: 75, max: 90)
            TableColumn("Remaining") { item in Text(item.remainingText).monospacedDigit() }.width(min: 65, ideal: 75, max: 90)

        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let item = model.transfers.first(where: { ids.contains($0.id) }) {
                Button("Download Details") { model.onProgress?(item.id) }
                if item.state == .awaitingConfirmation { Button("Confirm…") { model.askToConfirm(item) } }
                if item.state == .completed {
                    Button("Open File") { model.openFile(item) }
                    Button("Show in Finder") { model.reveal(item) }
                }
            }
            if !ids.isEmpty {
                Divider()
                Button("Delete Downloads?", role: .destructive) { delete(ids) }
            }
        } primaryAction: { ids in
            guard let item = model.transfers.first(where: { ids.contains($0.id) }) else { return }
            if item.state == .awaitingConfirmation { model.askToConfirm(item) }
            else { model.onProgress?(item.id) }
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "No downloads yet" : "No matching downloads", systemImage: "tray")
                } description: { Text("Add a link or download a file from Edge.") }
                actions: {
                    Button("Add download link") { showLink = true }
                    Button("Edge Settings…", action: openPreferences)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private func matchesType(_ item: Transfer) -> Bool {
        guard fileKind != "All Types" else { return true }
        guard let type = UTType(filenameExtension: (item.displayName as NSString).pathExtension) else { return false }
        switch fileKind {
        case "Images": return type.conforms(to: .image)
        case "Video": return type.conforms(to: .movie)
        case "Archives": return type.conforms(to: .archive) || type.conforms(to: .diskImage)
        default: return type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .content)
        }
    }

    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        deletion = DownloadDeletion(ids: ids)
    }
}

private struct DownloadDeletion: Identifiable {
    let id = UUID()
    let ids: Set<UUID>
}

private enum DownloadScope: String, CaseIterable, Identifiable {
    case all, active, waiting, paused, completed, attention
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .active: "In progress"
        case .waiting: "Waiting"
        case .paused: "Paused"
        case .completed: "Finished"
        case .attention: "Needs Attention"
        }
    }
    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .waiting: "clock"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .attention: "exclamationmark.circle"
        }
    }
    func includes(_ item: Transfer) -> Bool {
        switch self {
        case .all: true
        case .active: item.state == .downloading
        case .waiting: item.state == .queued || item.state == .awaitingConfirmation
        case .paused: item.state == .paused
        case .completed: item.state.terminal && item.state != .failed
        case .attention: item.state == .failed
        }
    }
}

extension Transfer {
    var statusText: String {
        switch state {
        case .awaitingConfirmation: String(localized: "Waiting for confirmation")
        case .queued: String(localized: "Waiting")
        case .downloading: fraction.map { String(format: "%.0f%%", $0 * 100) } ?? String(localized: "Downloading")
        case .paused: String(localized: "Paused")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Download failed")
        case .canceled: String(localized: "Canceled")
        case .handedToBrowser: String(localized: "Sent back to Edge.")
        }
    }
    var remainingText: String {
        guard state == .downloading else { return "—" }
        guard speed > 0, total > received else { return String(localized: "Estimating…") }
        let seconds = (total - received) / speed
        return Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }
}

struct TransferInspector: View {
    let transfer: Transfer
    let model: DownloadModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(transfer.displayName).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(transfer.statusText).foregroundStyle(.secondary)
            Divider()
            LabeledContent("Downloaded", value: Format.bytes(transfer.received))
            LabeledContent("File Size", value: transfer.total > 0 ? Format.bytes(transfer.total) : "—")
            LabeledContent("Remaining", value: transfer.remainingText)
            LabeledContent("Active Connections", value: String(transfer.connections))
            Divider()
            Text("Save files to").font(.subheadline.weight(.medium))
            Text(transfer.finalPath ?? model.workspace.directory(for: transfer).path)
                .font(.caption).textSelection(.enabled)
            if let source = transfer.sourceURL {
                Text("Source").font(.subheadline.weight(.medium))
                Text(source.absoluteString).font(.caption).textSelection(.enabled)
            }
            if let message = transfer.message { Text(message).foregroundStyle(.orange) }
            if transfer.state == .awaitingConfirmation {
                Button("Confirm…") { model.askToConfirm(transfer) }.buttonStyle(.borderedProminent)
            } else {
                Button("Download Details") { model.onProgress?(transfer.id) }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AddDownloadsView: View {
    let model: DownloadModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Downloads").font(.title2.weight(.semibold))
            Text("Paste one HTTP or HTTPS link per line.").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced()).frame(height: 150).border(.quaternary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Paste") { text = NSPasteboard.general.string(forType: .string) ?? "" }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Download") {
                    do { try model.addLinks(text); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }.padding(24).frame(width: 500)
    }
}

private struct DeleteDownloadsView: View {
    let ids: Set<UUID>
    let model: DownloadModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("deleteFilesByDefault") private var defaultFiles = true
    @State private var files = true
    @State private var remember = false
    @State private var deleting = false
    private var items: [Transfer] { model.transfers.filter { ids.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Delete Downloads?", systemImage: "trash").font(.title2.weight(.semibold))
            Text("\(items.count) downloads · \(Format.bytes(items.reduce(0) { $0 + $1.received }))")
            Picker("Delete", selection: $files) {
                Text("Delete Files and History").tag(true)
                Text("Delete History Only").tag(false)
            }.pickerStyle(.radioGroup)
            Text(files ? "Files will be moved to Trash. Active downloads will be stopped." : "Downloaded files will stay on disk.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Remember this choice", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    if remember { defaultFiles = files }
                    deleting = true
                    Task { await model.delete(ids, files: files); dismiss() }
                }.tint(.red).buttonStyle(.borderedProminent)
            }.disabled(deleting)
        }.padding(24).frame(width: 440).onAppear { files = defaultFiles }
            .interactiveDismissDisabled(deleting)
    }
}
