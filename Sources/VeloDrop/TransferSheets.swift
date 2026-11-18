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
    @State private var filename: String
    @State private var later = false
    @State private var filePolicy: ExistingFilePolicy

    init(transfer: Transfer, model: DownloadModel) {
        self.transfer = transfer
        self.model = model
        _filePolicy = State(initialValue: model.existingFilePolicy)
        _filename = State(initialValue: transfer.name)
        _directory = State(initialValue: URL(fileURLWithPath: transfer.destinationPath ?? model.defaultFolder))
        _connections = State(initialValue: transfer.connectionLimit ?? model.maxConnections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm Download").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                TextField("Filename", text: $filename).textFieldStyle(.roundedBorder)
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
                    Menu("Recent Folders") {
                        ForEach(model.recentFolders, id: \.self) { path in
                            Button(path) { directory = URL(fileURLWithPath: path) }
                        }
                    }.disabled(model.recentFolders.isEmpty)
                    Button("Choose Folder…") { choosingFolder = true }
                }
                if let folderError {
                    Text(folderError).font(.caption).foregroundStyle(.orange)
                }
            }
            Picker("Connections per file", selection: $connections) {
                ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
            }
            ExistingFilePicker(selection: $filePolicy)
            if filePolicy == .replace {
                Text("An existing file with the same name will be replaced.").font(.caption).foregroundStyle(.orange)
            }
            Toggle("Download later", isOn: $later)
            if model.transfers.filter({ $0.state == .awaitingConfirmation }).count > 1 {
                Text("Other downloads are waiting for confirmation.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel download", role: .cancel) { model.cancel(transfer) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Edge") { model.useEdge(transfer) }
                Button("Use VeloDrop") {
                    model.confirm(transfer, into: directory, connections: connections, name: filename, later: later, filePolicy: filePolicy)
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                if item.state == .completed, let path = item.finalPath, !FileManager.default.fileExists(atPath: path) {
                    Label("File moved or deleted", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                HStack {
                    ProgressView(value: item.fraction ?? 0)
                    if let fraction = item.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                }
                HStack {
                    Text("\(Format.bytes(item.received)) / \(item.total > 0 ? Format.bytes(item.total) : "—")")
                    Spacer()
                    Text(Format.rate(item.speed)).monospacedDigit()
                }
                LabeledContent("Remaining", value: item.remainingText)
                LabeledContent("Active Connections", value: "\(item.connections) / \(item.connectionLimit ?? model.maxConnections)")
                Picker("Speed Limit", selection: Binding(
                    get: { item.speedLimit ?? 0 },
                    set: { model.setSpeed(id, bytesPerSecond: $0) }
                )) {
                    Text("Unlimited").tag(Int64(0))
                    Text("1 MB/s").tag(Int64(1_000_000))
                    Text("5 MB/s").tag(Int64(5_000_000))
                    Text("10 MB/s").tag(Int64(10_000_000))
                }.disabled(item.state.terminal)
                Picker("Priority", selection: Binding(
                    get: { item.priority ?? 0 },
                    set: { model.setPriority(id, priority: $0) }
                )) {
                    Text("Normal").tag(0)
                    Text("High").tag(1)
                }.disabled(item.state.terminal)
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
        case .handedToBrowser: return "Sent back to Edge."
        }
    }
}

struct ExistingFilePicker: View {
    @Binding var selection: ExistingFilePolicy
    var body: some View {
        Picker("If a file already exists", selection: $selection) {
            Text("Keep both files").tag(ExistingFilePolicy.rename)
            Text("Skip download").tag(ExistingFilePolicy.skip)
            Text("Replace existing file").tag(ExistingFilePolicy.replace)
        }
    }
}
