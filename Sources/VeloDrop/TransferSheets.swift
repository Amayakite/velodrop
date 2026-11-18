import SwiftUI
import UniformTypeIdentifiers
import VeloCore

struct DownloadConfirmationView: View {
    let transfer: Transfer
    let model: DownloadModel
    @State private var directory: URL
    @State private var choosingFolder = false
    @State private var connections: Int
    @State private var folderError: String?

    init(transfer: Transfer, model: DownloadModel) {
        self.transfer = transfer
        self.model = model
        _directory = State(initialValue: model.workspace.directory(for: transfer))
        _connections = State(initialValue: transfer.connectionLimit ?? model.maxConnections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm Download").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text(transfer.displayName).font(.headline).lineLimit(2)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("Save files to").font(.subheadline.weight(.medium))
                HStack {
                    Text(directory.path(percentEncoded: false))
                        .lineLimit(1).truncationMode(.head)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose Folder…") { choosingFolder = true }
                }
                if let folderError {
                    Text(folderError).font(.caption).foregroundStyle(.orange)
                }
            }
            Picker("Connections per file", selection: $connections) {
                ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
            }
            HStack {
                Spacer()
                Button("Cancel and Continue in Edge", role: .cancel) { model.useEdge(transfer) }
                    .keyboardShortcut(.cancelAction)
                Button("Start Download") { model.confirm(transfer, into: directory, connections: connections) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 480)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do {
                directory = try result.get()
                folderError = nil
            } catch {
                folderError = error.localizedDescription
            }
        }
        .interactiveDismissDisabled()
    }

    private var description: String {
        [transfer.sourceURL?.host, transfer.total > 0 ? Format.bytes(transfer.total) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct TransferDetailsView: View {
    let transfer: Transfer
    let defaultDirectory: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Download Details").font(.title2.weight(.semibold))
                Text(transfer.displayName).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            Form {
                Section("File") {
                    LabeledContent("File Size", value: transfer.total > 0 ? Format.bytes(transfer.total) : "—")
                    if let type = fileType {
                        LabeledContent("File Type", value: type)
                    }
                    LabeledContent("Save files to") {
                        Text(transfer.finalPath ?? transfer.destinationPath ?? defaultDirectory.path)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    LabeledContent("Added", value: transfer.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let finished = transfer.finishedAt ?? (transfer.state.terminal ? transfer.updatedAt : nil) {
                        LabeledContent("Ended", value: finished.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section("Request") {
                    LabeledContent("Added from") {
                        Text(transfer.fromBrowser ? "Microsoft Edge" : String(localized: "Manually Added"))
                    }
                    if let source = transfer.sourceURL {
                        linkRow("Source", url: source)
                    }
                    if let page = transfer.referringPage {
                        linkRow("Referring Page", url: page)
                    }
                    if let proxy = transfer.effectiveProxy ?? transfer.browserProxy {
                        LabeledContent("Proxy", value: describe(proxy))
                    }
                    if let headers = transfer.browserHeaderNames, !headers.isEmpty {
                        LabeledContent("Browser Headers", value: headers.joined(separator: ", "))
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 330)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480)
    }

    private var fileType: String? {
        if let mime = transfer.mimeType, !mime.isEmpty { return mime }
        return UTType(filenameExtension: (transfer.displayName as NSString).pathExtension)?.localizedDescription
    }

    private func linkRow(_ title: LocalizedStringKey, url: URL) -> some View {
        LabeledContent(title) {
            Text(url.absoluteString).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func describe(_ proxy: BrowserProxy) -> String {
        switch proxy.mode {
        case .direct: return String(localized: "Direct Connection")
        case .system: return String(localized: "macOS System Proxy")
        case .fixed: return proxy.endpoint?.absoluteString ?? "—"
        }
    }
}

struct DownloadProgressView: View {
    let id: UUID
    let model: DownloadModel
    @State private var showDetails = false

    private var transfer: Transfer? { model.transfers.first { $0.id == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let item = transfer {
                Text(item.displayName).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(LocalizedStringKey(status(item))).foregroundStyle(.secondary)
                ProgressView(value: item.fraction ?? 0)
                HStack {
                    Text("\(Format.bytes(item.received)) / \(item.total > 0 ? Format.bytes(item.total) : "—")")
                    Spacer()
                    Text(Format.rate(item.speed)).monospacedDigit()
                }
                LabeledContent("Active Connections", value: String(item.connections))
                Picker("Connections per file", selection: Binding(
                    get: { item.connectionLimit ?? model.maxConnections },
                    set: { model.setConnections(id, count: $0) }
                )) {
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                }.disabled(item.state.terminal)
                Text("Changing connections briefly reconnects the download. Actual connections depend on file size and server support.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Save files to", value: item.finalPath ?? model.workspace.directory(for: item).path)
                    .textSelection(.enabled)
                if let message = item.message { Text(message).foregroundStyle(.orange) }
                Divider()
                HStack {
                    Button("Download Details") { showDetails = true }
                    Spacer()
                    if item.state.running {
                        Button("Pause") { model.pause(item) }
                    } else if item.state == .paused {
                        Button("Resume") { model.resume(item) }
                    }
                    if !item.state.terminal {
                        Button("Cancel download", role: .destructive) { model.cancel(item) }
                    } else if item.state == .completed {
                        Button("Show in Finder") { model.reveal(item) }
                        Button("Open File") { model.openFile(item) }.buttonStyle(.borderedProminent)
                    }
                }
                .sheet(isPresented: $showDetails) {
                    TransferDetailsView(transfer: item, defaultDirectory: model.workspace.destination)
                }
            } else {
                Text("Download removed")
            }
        }
        .padding(24).frame(width: 500)
    }

    private func status(_ item: Transfer) -> String {
        switch item.state {
        case .awaitingConfirmation: return "Waiting for confirmation"
        case .queued: return "Waiting"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Download failed"
        case .canceled: return "Canceled"
        }
    }
}
