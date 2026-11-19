import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeloCore

// MARK: - Browser download confirmation

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
        VStack(spacing: 0) {
            header
            Divider().overlay(VD.hairline)
            VStack(alignment: .leading, spacing: 12) {
                destinationCard
                optionsCard
                if filePolicy == .replace {
                    Label("An existing file with the same name will be replaced.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(VD.orange)
                        .padding(.horizontal, 2)
                }
                if let folderError {
                    Label(folderError, systemImage: "exclamationmark.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(VD.red)
                        .padding(.horizontal, 2)
                }
                if waitingCount > 1 {
                    Label("Other downloads are waiting for confirmation.", systemImage: "clock")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
            }
            .padding(20)
            Divider().overlay(VD.hairline)
            footer
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var waitingCount: Int {
        model.transfers.filter { $0.state == .awaitingConfirmation }.count
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            FileIconTile(transfer: transfer, size: 52)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    SectionEyebrow(text: "Confirm Download")
                    StatusBadge(state: .awaitingConfirmation, text: "From Edge", compact: true)
                }
                TextField("Filename", text: $filename)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(VD.hairline, lineWidth: 0.8)
                    )
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 9))
                    Text(transfer.sourceURL?.host ?? "")
                    if transfer.total > 0 {
                        Text("·")
                        Text(Format.bytes(transfer.total))
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(VD.accent)
                Text("Save files to")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if !model.recentFolders.isEmpty {
                    Menu("Recent Folders") {
                        ForEach(model.recentFolders, id: \.self) { path in
                            Button(path) { directory = URL(fileURLWithPath: path) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button("Choose Folder…") { choosingFolder = true }
                    .buttonStyle(VDSecondaryButtonStyle(compact: true))
            }
            Text(directory.path(percentEncoded: false))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .vdCard(padding: 12)
    }

    private var optionsCard: some View {
        VStack(spacing: 0) {
            settingRow(icon: "point.3.connected.trianglepath.dotted", title: "Connections per file") {
                Picker("Connections per file", selection: $connections) {
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .menuStyle(.borderlessButton)
                .frame(width: 68)
            }
            Divider().overlay(VD.hairline).padding(.leading, 30)
            settingRow(icon: "doc.on.doc", title: "If a file already exists") {
                Picker("If a file already exists", selection: $filePolicy) {
                    Text("Keep both files").tag(ExistingFilePolicy.rename)
                    Text("Skip download").tag(ExistingFilePolicy.skip)
                    Text("Replace existing file").tag(ExistingFilePolicy.replace)
                }
                .labelsHidden()
                .menuStyle(.borderlessButton)
                .frame(width: 170)
            }
            Divider().overlay(VD.hairline).padding(.leading, 30)
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Toggle("Download later", isOn: $later)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                Spacer()
            }
            .padding(.vertical, 9)
        }
        .padding(.horizontal, 12)
        .background(VD.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(VD.hairline, lineWidth: 0.8)
        )
    }

    private func settingRow<Control: View>(icon: String, title: LocalizedStringKey,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5))
            Spacer()
            control()
        }
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Cancel download", role: .cancel) { model.cancel(transfer) }
                .buttonStyle(VDSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Use Edge") { model.useEdge(transfer) }
                .buttonStyle(VDSecondaryButtonStyle())
            Button("Use VeloDrop") {
                model.confirm(transfer, into: directory, connections: connections,
                              name: filename, later: later, filePolicy: filePolicy)
            }
            .buttonStyle(VDPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
    }
}

// MARK: - Transfer details

struct TransferDetailsView: View {
    let transfer: Transfer
    let defaultDirectory: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                FileIconTile(transfer: transfer, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download Details")
                        .font(.system(size: 16, weight: .semibold))
                    Text(transfer.displayName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                StatusBadge(state: transfer.state, text: transfer.state.shortStatusKey)
            }
            .padding(18)
            Divider().overlay(VD.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailSection("File") {
                        detailRow("File Size", transfer.total > 0 ? Format.bytes(transfer.total) : "—")
                        if let type = fileType {
                            detailRow("File Type", type)
                        }
                        detailRow("Save files to", transfer.finalPath ?? transfer.destinationPath ?? defaultDirectory.path,
                                  monospaced: true)
                        detailRow("Added", Format.dateTime(transfer.createdAt))
                        if let finished = transfer.finishedAt ?? (transfer.state.terminal ? transfer.updatedAt : nil) {
                            detailRow("Ended", Format.dateTime(finished))
                        }
                    }
                    detailSection("Request") {
                        detailRow("Added from", transfer.fromBrowser ? "Microsoft Edge" : String(localized: "Manually Added"))
                        if let source = transfer.sourceURL {
                            detailRow("Source", source.absoluteString, monospaced: true)
                        }
                        if let page = transfer.referringPage {
                            detailRow("Referring Page", page.absoluteString, monospaced: true)
                        }
                        if let proxy = transfer.effectiveProxy ?? transfer.browserProxy {
                            detailRow("Proxy", describe(proxy))
                        }
                        if let headers = transfer.browserHeaderNames, !headers.isEmpty {
                            detailRow("Browser Headers", headers.joined(separator: ", "))
                        }
                    }
                }
                .padding(16)
            }
            .frame(height: 340)
            Divider().overlay(VD.hairline)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(VDPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fileType: String? {
        if let mime = transfer.mimeType, !mime.isEmpty { return mime }
        return UTType(filenameExtension: (transfer.displayName as NSString).pathExtension)?.localizedDescription
    }

    private func detailSection<Content: View>(_ title: LocalizedStringKey,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(text: title)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 11)
                .padding(.vertical, 3)
                .background(VD.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(VD.hairline, lineWidth: 0.8)
                )
        }
    }

    private func detailRow(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: monospaced ? 9.5 : 10.5, design: monospaced ? .monospaced : .default))
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Divider().overlay(VD.hairline.opacity(0.5))
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

// MARK: - Download progress

struct DownloadProgressView: View {
    let id: UUID
    let model: DownloadModel
    @State private var showDetails = false

    private var transfer: Transfer? { model.transfers.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 0) {
            if let item = transfer {
                header(item)
                Divider().overlay(VD.hairline)
                VStack(alignment: .leading, spacing: 13) {
                    progressCard(item)
                    tuningCard(item)
                    Text("Changing connections briefly reconnects the download. Actual connections depend on file size and server support.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = item.message, item.state == .failed {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(VD.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    locationCard(item)
                }
                .padding(18)
                Divider().overlay(VD.hairline)
                footer(item)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Download removed")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            }
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showDetails) {
            if let item = transfer {
                TransferDetailsView(transfer: item, defaultDirectory: model.workspace.destination)
            }
        }
    }

    private func header(_ item: Transfer) -> some View {
        HStack(alignment: .top, spacing: 13) {
            FileIconTile(transfer: item, size: 50)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayName)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    StatusBadge(state: item.state, text: item.state.shortStatusKey)
                    if let host = item.sourceURL?.host {
                        Text(host)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if item.state == .completed, let path = item.finalPath,
               !FileManager.default.fileExists(atPath: path) {
                Label("File moved or deleted", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(VD.orange)
            }
        }
        .padding(18)
    }

    private func progressCard(_ item: Transfer) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(item.state == .downloading ? Format.rate(item.speed) : "—")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(item.state == .downloading ? VD.accent : .secondary)
                        .monospacedDigit()
                    Text(item.remainingText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            VDProgressBar(fraction: item.fraction, tint: item.state.tint, height: 9)
            HStack {
                Text(item.total > 0
                     ? String(localized: "\(Format.bytes(item.received)) of \(Format.bytes(item.total))")
                     : Format.bytes(item.received))
                Spacer()
                Text("\(item.connections) connections")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .vdCard(padding: 15)
    }

    private func tuningCard(_ item: Transfer) -> some View {
        VStack(spacing: 0) {
            tuningRow(icon: "speedometer", title: "Speed Limit") {
                Picker("Speed Limit", selection: Binding(
                    get: { item.speedLimit ?? 0 },
                    set: { model.setSpeed(id, bytesPerSecond: $0) }
                )) {
                    Text("Unlimited").tag(Int64(0))
                    Text("1 MB/s").tag(Int64(1_000_000))
                    Text("5 MB/s").tag(Int64(5_000_000))
                    Text("10 MB/s").tag(Int64(10_000_000))
                }
                .labelsHidden()
                .menuStyle(.borderlessButton)
                .frame(width: 120)
            }
            Divider().overlay(VD.hairline).padding(.leading, 30)
            tuningRow(icon: "bolt.fill", title: "Priority") {
                Picker("Priority", selection: Binding(
                    get: { item.priority ?? 0 },
                    set: { model.setPriority(id, priority: $0) }
                )) {
                    Text("Normal").tag(0)
                    Text("High").tag(1)
                }
                .labelsHidden()
                .menuStyle(.borderlessButton)
                .frame(width: 120)
            }
            Divider().overlay(VD.hairline).padding(.leading, 30)
            tuningRow(icon: "point.3.connected.trianglepath.dotted", title: "Connections per file") {
                Picker("Connections per file", selection: Binding(
                    get: { item.connectionLimit ?? model.maxConnections },
                    set: { model.setConnections(id, count: $0) }
                )) {
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .menuStyle(.borderlessButton)
                .frame(width: 120)
            }
        }
        .padding(.horizontal, 13)
        .background(VD.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(VD.hairline, lineWidth: 0.8)
        )
        .disabled(item.state.terminal)
    }

    private func tuningRow<Control: View>(icon: String, title: LocalizedStringKey,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5))
            Spacer()
            control()
        }
        .padding(.vertical, 5)
    }

    private func locationCard(_ item: Transfer) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                SectionEyebrow(text: "Save files to")
                Text(item.finalPath ?? model.workspace.directory(for: item).path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func footer(_ item: Transfer) -> some View {
        HStack(spacing: 8) {
            Button("Download Details") { showDetails = true }
                .buttonStyle(VDSecondaryButtonStyle())
            Spacer()
            if item.state.running {
                Button("Pause") { model.pause(item) }
                    .buttonStyle(VDSecondaryButtonStyle())
                Button("Cancel download", role: .destructive) { model.cancel(item) }
                    .buttonStyle(VDDangerButtonStyle())
            } else if item.state == .paused {
                Button("Cancel download", role: .destructive) { model.cancel(item) }
                    .buttonStyle(VDDangerButtonStyle())
                Button("Resume") { model.resume(item) }
                    .buttonStyle(VDPrimaryButtonStyle())
            } else if item.state == .completed {
                Button("Show in Finder") { model.reveal(item) }
                    .buttonStyle(VDSecondaryButtonStyle())
                Button("Open File") { model.openFile(item) }
                    .buttonStyle(VDPrimaryButtonStyle())
            } else if item.state == .failed, item.url != nil {
                Button("Cancel download", role: .destructive) { model.cancel(item) }
                    .buttonStyle(VDDangerButtonStyle())
                Button("Retry") { model.resume(item) }
                    .buttonStyle(VDPrimaryButtonStyle())
            } else if item.state == .awaitingConfirmation {
                Button("Cancel download", role: .destructive) { model.cancel(item) }
                    .buttonStyle(VDDangerButtonStyle())
                Button("Confirm…") { model.askToConfirm(item) }
                    .buttonStyle(VDPrimaryButtonStyle())
            }
        }
        .padding(15)
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
