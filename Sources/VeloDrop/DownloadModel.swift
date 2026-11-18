import AppKit
import Foundation
import Observation
import VeloCore

@MainActor @Observable
final class DownloadModel {
    private(set) var transfers: [Transfer] = []
    var notice: String?
    var maxConnections: Int {
        didSet { UserDefaults.standard.set(maxConnections, forKey: "maxConnections") }
    }

    var confirmBrowserDownloads: Bool {
        didSet { UserDefaults.standard.set(confirmBrowserDownloads, forKey: "confirmBrowserDownloads") }
    }
    var showWindowOnCapture: Bool {
        didSet { UserDefaults.standard.set(showWindowOnCapture, forKey: "showWindowOnCapture") }
    }
    var confirmation: Transfer? {
        didSet { onConfirmationChanged?() }
    }
    @ObservationIgnored var onConfirmationChanged: (() -> Void)?
    @ObservationIgnored var onProgress: ((UUID) -> Void)?

    @ObservationIgnored var onBrowserIntake: (() -> Void)?
    @ObservationIgnored private var shouldShowIntake = false
    @ObservationIgnored private var browserHeaders: [UUID: BrowserHeaders] = [:]

    let workspace: Workspace
    @ObservationIgnored private let engine: AriaEngine
    @ObservationIgnored private var inbox: FolderMonitor?
    @ObservationIgnored private var abandons: FolderMonitor?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lockDescriptor: Int32 = -1
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var lastHeartbeat = Date.distantPast

    init(workspace: Workspace = .standard()) {
        self.workspace = workspace
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/aria2c")
        let override = ProcessInfo.processInfo.environment["VELODROP_ENGINE"].map { URL(fileURLWithPath: $0) }
        self.engine = AriaEngine(executable: override ?? executable, workingDirectory: workspace.root)
        self.maxConnections = [1, 4, 8, 16].contains(UserDefaults.standard.integer(forKey: "maxConnections"))
            ? UserDefaults.standard.integer(forKey: "maxConnections") : 8
        confirmBrowserDownloads = UserDefaults.standard.object(forKey: "confirmBrowserDownloads") == nil
            ? true : UserDefaults.standard.bool(forKey: "confirmBrowserDownloads")
        showWindowOnCapture = UserDefaults.standard.object(forKey: "showWindowOnCapture") as? Bool ?? true

        do {
            try workspace.prepare()
            lockDescriptor = open(workspace.root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                if lockDescriptor >= 0 { close(lockDescriptor) }
                lockDescriptor = -1
                notice = String(localized: "VeloDrop is already running.")
                return
            }
            workspace.expireOldOutcomes()
            transfers = workspace.all()
            for var transfer in transfers where transfer.state.running || transfer.state == .paused {
                if let output = workspace.recoveredOutput(transfer) {
                    finish(transfer, at: output)
                    continue
                }
                guard transfer.state.running else { continue }
                transfer.state = .queued
                transfer.speed = 0
                transfer.connections = 0
                save(transfer)
            }
            inbox = FolderMonitor(workspace.inbox) { [weak self] in self?.drainInbox() }
            abandons = FolderMonitor(workspace.abandons) { [weak self] in self?.startLoop() }
            drainInbox()
        } catch {
            notice = error.localizedDescription
        }
    }

    var activeCount: Int { transfers.filter { $0.state.running }.count }
    var rate: Int64 { transfers.reduce(0) { $0 + $1.speed } }

    func add(_ text: String) throws {
        guard lockDescriptor >= 0, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              Transfer.supports(url) else { throw TransferError.invalidURL }
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "Download") : url.lastPathComponent
        let transfer = try Transfer(url: url, name: name, fromBrowser: false)
        try workspace.update(transfer)
        transfers.insert(transfer, at: 0)
        startLoop()
    }

    func pause(_ transfer: Transfer) { change(transfer.id, to: .paused) }
    func resume(_ transfer: Transfer) { change(transfer.id, to: .queued) }
    func cancel(_ transfer: Transfer) {
        change(transfer.id, to: .canceled)
        if confirmation?.id == transfer.id { confirmation = nil }
    }

    func useEdge(_ transfer: Transfer) {
        change(transfer.id, to: .failed, message: String(localized: "Sent back to Edge."))
        if confirmation?.id == transfer.id { confirmation = nil }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.edgemac")
            .first?.activate()
    }

    func showPendingIntake() {
        guard shouldShowIntake, let onBrowserIntake else { return }
        shouldShowIntake = false
        onBrowserIntake()
    }

    func askToConfirm(_ transfer: Transfer) {
        guard transfer.state == .awaitingConfirmation else { return }
        confirmation = transfer
        showPendingIntake()
    }

    func confirmNextIfNeeded() {
        guard confirmation == nil, let pending = transfers.last(where: { $0.state == .awaitingConfirmation }) else { return }
        confirmation = pending
    }

    func confirm(_ transfer: Transfer, into directory: URL, connections: Int) {
        guard var item = transfers.first(where: { $0.id == transfer.id }),
              item.state == .awaitingConfirmation else { return }
        item.connectionLimit = connections
        item.destinationPath = directory.standardizedFileURL.path
        item.state = .queued
        save(item)
        confirmation = nil
        onProgress?(item.id)
        startLoop()
    }

    func setConnections(_ id: UUID, count: Int) {
        guard (1...16).contains(count),
              var item = transfers.first(where: { $0.id == id }), !item.state.terminal else { return }
        item.connectionLimit = count
        save(item)
        startLoop()
    }

    func delete(_ ids: Set<UUID>, files: Bool) async {
        for id in ids {
            guard let item = transfers.first(where: { $0.id == id }) else { continue }
            if !item.state.terminal { cancel(item) }
            await engine.remove(id)
            guard let current = transfers.first(where: { $0.id == id }) else { continue }
            if files && current.finalPath != nil { trash(current) }
            else { removeHistory(current) }
        }
    }

    func reveal(_ transfer: Transfer) {
        if let path = transfer.finalPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    func openFile(_ transfer: Transfer) {
        if let path = transfer.finalPath, !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            notice = String(localized: "The downloaded file could not be opened.")
        }
    }

    func removeHistory(_ transfer: Transfer) {
        guard let item = transfers.first(where: { $0.id == transfer.id }), item.state.terminal else { return }
        do {
            try workspace.removeHistory(item)
            try? FileManager.default.removeItem(at: workspace.stage(item.id))
            transfers.removeAll { $0.id == item.id }
        } catch {
            notice = error.localizedDescription
        }
    }

    func trash(_ transfer: Transfer) {
        guard transfer.state == .completed, let path = transfer.finalPath else { return }
        let url = URL(fileURLWithPath: path)
        guard workspace.ownsPublishedFile(url, id: transfer.id) else {
            notice = String(localized: "The original downloaded file is no longer at this location.")
            return
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            removeHistory(transfer)
        } catch {
            notice = error.localizedDescription
        }
    }

    func shutdown() {
        shuttingDown = true
        loop?.cancel()
        engine.stop()
    }

    private func change(_ id: UUID, to state: TransferState, message: String? = nil) {
        guard var item = transfers.first(where: { $0.id == id }) else { return }
        if state == .queued, item.url == nil { return }
        if state == .paused, !item.state.running { return }
        if state == .canceled, item.state.terminal { return }
        if state == .failed, item.state.terminal { return }
        item.state = state
        item.message = message
        item.speed = 0
        item.connections = 0
        item.finishedAt = state.terminal ? Date() : nil
        if state.terminal { browserHeaders.removeValue(forKey: id) }
        if state == .canceled || (state == .failed && item.fromBrowser) { item.url = nil }
        save(item)
        startLoop()
    }

    private func save(_ transfer: Transfer, refreshUI: Bool = true) {
        var updated = transfer
        updated.updatedAt = Date()
        do {
            try workspace.update(updated)
            guard refreshUI else { return }
            if let index = transfers.firstIndex(where: { $0.id == updated.id }) {
                transfers[index] = updated
            } else {
                transfers.insert(updated, at: 0)
            }
        } catch {
            notice = String(localized: "Couldn’t save the download state. \(error.localizedDescription)")
        }
    }

    private func drainInbox() {
        for (path, var transfer, headers) in workspace.incoming() {
            if workspace.browserStatus(transfer.id) == nil && !workspace.wasAbandoned(transfer.id) {
                if confirmBrowserDownloads && transfer.fromBrowser {
                    transfer.state = .awaitingConfirmation
                }
                save(transfer)
                if transfers.contains(where: { $0.id == transfer.id }) {
                    if !headers.fields.isEmpty { browserHeaders[transfer.id] = headers }
                    if transfer.state == .awaitingConfirmation && confirmation == nil {
                        confirmation = transfer
                    }
                    if transfer.fromBrowser && (showWindowOnCapture || transfer.state == .awaitingConfirmation) {
                        shouldShowIntake = true
                    }
                }
            }
            try? FileManager.default.removeItem(at: path)
        }
        showPendingIntake()
        startLoop()
    }

    private func attach(_ transfer: Transfer) async throws {
        var item = transfer
        let headers = browserHeaders[item.id]
        if item.requiresBrowserSession == true && headers?.requiresSession != true {
            throw TransferError.engine(String(localized: "The browser session is no longer available."))
        }
        guard let url = item.url else { throw TransferError.invalidURL }
        item.effectiveProxy = try ProxyRouting.route(item.browserProxy, for: url)
        if item.effectiveProxy != transfer.effectiveProxy { save(item) }
        try await engine.add(item, stage: workspace.stage(item.id), connections: item.connectionLimit ?? maxConnections, headers: headers)
    }

    private func startLoop() {
        guard !shuttingDown, loop == nil, lockDescriptor >= 0 else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            await self.run()
            self.loop = nil
        }
    }

    private func run() async {
        while !Task.isCancelled {
            let snapshot = transfers
            for item in snapshot where item.fromBrowser && !item.state.terminal && workspace.wasAbandoned(item.id) {
                change(item.id, to: .canceled)
                if confirmation?.id == item.id { confirmation = nil }
            }

            let stale = engine.attached.filter { id in transfers.first { $0.id == id }?.state.terminal ?? true }
            for id in stale {
                await engine.remove(id)
            }
            for item in transfers where item.state == .canceled || (item.fromBrowser && item.state == .failed) {
                try? FileManager.default.removeItem(at: workspace.stage(item.id))
            }

            let running = transfers.filter { $0.state.running }
            let paused = transfers.filter { $0.state == .paused && engine.attached.contains($0.id) }
            if running.isEmpty && paused.isEmpty {
                engine.stop()
                return
            }
            do {
                try await engine.start()
                for item in transfers where engine.attached.contains(item.id) && !item.state.terminal {
                    try await engine.configure(item.id, connections: item.connectionLimit ?? maxConnections,
                                               resume: item.state.running)
                }
                let statuses = try await engine.statuses(Array(engine.attached))
                for item in paused {
                    if statuses[item.id]?.status == "complete" { await update(item.id, with: statuses[item.id]); continue }
                    if let status = statuses[item.id], status.status == "active" || status.status == "waiting" {
                        try await engine.pause(item.id)
                    }
                }
                for item in running.sorted(by: { $0.createdAt < $1.createdAt }) {
                    guard let current = transfers.first(where: { $0.id == item.id }), current.state.running else { continue }
                    if let status = statuses[item.id] {
                        if status.status == "paused" {
                            try await attach(current)
                        } else {
                            await update(item.id, with: status)
                        }
                    } else if engine.attached.contains(item.id) {
                        await engine.forget(item.id)
                        change(item.id, to: .failed, message: String(localized: "The download engine lost this task."))
                    } else {
                        do {
                            try await attach(current)
                        } catch {
                            change(item.id, to: .failed, message: error.localizedDescription)
                        }
                    }
                }
                if !transfers.contains(where: { $0.state.running }) &&
                    !paused.contains(where: { statuses[$0.id]?.status == "active" || statuses[$0.id]?.status == "waiting" }) {
                    engine.stop()
                    return
                }
            } catch {
                if Task.isCancelled { return }
                engine.stop()
                for item in transfers where item.state.running {
                    change(item.id, to: .failed, message: String(localized: "The download engine disconnected."))
                }
            }

            if Date().timeIntervalSince(lastHeartbeat) >= 5 {
                lastHeartbeat = Date()
                for item in transfers where !item.state.terminal && item.fromBrowser {
                    save(item, refreshUI: false)
                }
            }
            let hasNewTransfer = transfers.contains { $0.state == .queued }
            try? await Task.sleep(for: .milliseconds(hasNewTransfer ? 180 : 850))
        }
    }

    private func finish(_ transfer: Transfer, at file: URL) {
        var completed = transfer
        completed.state = .completed
        completed.finalPath = file.path
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            completed.received = Int64(size)
            completed.total = Int64(size)
        }
        completed.url = nil
        completed.speed = 0
        completed.connections = 0
        completed.finishedAt = Date()
        browserHeaders.removeValue(forKey: completed.id)
        save(completed)
        if workspace.read(transfer.id)?.state == .completed {
            try? FileManager.default.removeItem(at: workspace.stage(transfer.id))
        }
    }

    private func update(_ id: UUID, with status: EngineStatus?) async {
        guard let status, var item = transfers.first(where: { $0.id == id }),
              !item.state.terminal else { return }
        item.received = status.received
        if status.total > 0 { item.total = status.total }
        item.speed = status.speed
        item.connections = status.peers
        switch status.status {
        case "complete":
            do {
                if item.fromBrowser && workspace.wasAbandoned(id) {
                    change(id, to: .canceled)
                } else {
                    finish(item, at: try workspace.publish(item))
                }
            } catch {
                change(id, to: .failed, message: error.localizedDescription)
            }
            await engine.forget(id)
        case "error", "removed":
            change(id, to: .failed, message: status.explanation)
            await engine.forget(id)
        case "active":
            guard item.state != .paused else { return }
            item.state = .downloading
            if let old = transfers.first(where: { $0.id == id }), item != old { save(item) }
        default: break
        }
    }
}
