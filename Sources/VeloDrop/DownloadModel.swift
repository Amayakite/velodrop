import AppKit
import Foundation
import Observation
import VeloCore

@MainActor @Observable
final class DownloadModel {
    private(set) var transfers: [Transfer] = []
    private(set) var duplicateInstance = false
    var notice: String?
    var simultaneousDownloads: Int {
        didSet { UserDefaults.standard.set(simultaneousDownloads, forKey: "simultaneousDownloads") }
    }
    var bandwidthLimit: Int64 {
        didSet { UserDefaults.standard.set(bandwidthLimit, forKey: "bandwidthLimit") }
    }
    var existingFilePolicy: ExistingFilePolicy {
        didSet { UserDefaults.standard.set(existingFilePolicy.rawValue, forKey: "existingFilePolicy") }
    }
    var defaultFolder: String {
        didSet { UserDefaults.standard.set(defaultFolder, forKey: "defaultFolder") }
    }
    var recentFolders: [String] {
        UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
    }

    var maxConnections: Int {
        didSet { UserDefaults.standard.set(maxConnections, forKey: "maxConnections") }
    }

    var confirmBrowserDownloads: Bool {
        didSet { UserDefaults.standard.set(confirmBrowserDownloads, forKey: "confirmBrowserDownloads") }
    }
    var showWindowOnCapture: Bool {
        didSet { UserDefaults.standard.set(showWindowOnCapture, forKey: "showWindowOnCapture") }
    }

    // Browser takeover rules live in the app. The extension asks for
    // them through VeloBridge, so users have one place to configure downloads.
    var browserTakeoverEnabled: Bool {
        didSet { persistBrowserRules() }
    }
    var browserMinimumMiB: Double {
        didSet { persistBrowserRules() }
    }
    var browserExcludedHosts: String {
        didSet { persistBrowserRules() }
    }
    var browserReuseSessionHeaders: Bool {
        didSet { persistBrowserRules() }
    }

    var browserRules: BrowserRules {
        BrowserRules(enabled: browserTakeoverEnabled,
                     minimumMiB: Self.clampedMinimum(browserMinimumMiB),
                     excludedHosts: browserExcludedHosts,
                     reuseSessionHeaders: browserReuseSessionHeaders)
    }

    private static func clampedMinimum(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 10_240) : 2
    }
    private(set) var confirmation: Transfer? {
        didSet { onConfirmationChanged?() }
    }
    @ObservationIgnored var onConfirmationChanged: (() -> Void)?
    @ObservationIgnored var onProgress: ((UUID) -> Void)?

    @ObservationIgnored var onBrowserIntake: (() -> Void)?
    @ObservationIgnored private var shouldShowIntake = false
    @ObservationIgnored var onTerminalIntake: (() -> Void)?
    @ObservationIgnored private var pendingTerminalIDs: [UUID] = []
    private(set) var terminalSelection: [UUID] = []
    var selectedDownloads: Set<UUID> = []
    private(set) var testingBrowser: BrowserID?
    private(set) var browserTestErrors: [BrowserID: String] = [:]
    @ObservationIgnored private var browserTestServer: BrowserTestServer?
    @ObservationIgnored private var browserTestTimeout: Task<Void, Never>?
    @ObservationIgnored private var browserTestID: UUID?
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
        existingFilePolicy = ExistingFilePolicy(rawValue: UserDefaults.standard.string(forKey: "existingFilePolicy") ?? "rename") ?? .rename
        simultaneousDownloads = max(1, min(10, UserDefaults.standard.object(forKey: "simultaneousDownloads") as? Int ?? 3))
        bandwidthLimit = Int64(max(0, UserDefaults.standard.integer(forKey: "bandwidthLimit")))
        defaultFolder = ProcessInfo.processInfo.environment["VELODROP_DESTINATION"] ?? UserDefaults.standard.string(forKey: "defaultFolder") ?? workspace.destination.path
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/aria2c")
        let override = ProcessInfo.processInfo.environment["VELODROP_ENGINE"].map { URL(fileURLWithPath: $0) }
        self.engine = AriaEngine(executable: override ?? executable, workingDirectory: workspace.root)
        self.maxConnections = (1...16).contains(UserDefaults.standard.integer(forKey: "maxConnections"))
            ? UserDefaults.standard.integer(forKey: "maxConnections") : 8
        confirmBrowserDownloads = UserDefaults.standard.object(forKey: "confirmBrowserDownloads") == nil
            ? true : UserDefaults.standard.bool(forKey: "confirmBrowserDownloads")
        showWindowOnCapture = UserDefaults.standard.object(forKey: "showWindowOnCapture") as? Bool ?? true

        // VeloDrop 0.5 stored these rules in the extension. Use the last synced
        // copy as the migration source until the user edits them in Settings.
        let legacyRules = (try? Data(contentsOf: workspace.root.appendingPathComponent("browser-rules.json")))
            .flatMap { try? JSONDecoder().decode(BrowserRules.self, from: $0) }
        let defaults = UserDefaults.standard
        browserTakeoverEnabled = defaults.object(forKey: "browserTakeoverEnabled") as? Bool
            ?? legacyRules?.enabled ?? true
        browserMinimumMiB = Self.clampedMinimum(defaults.object(forKey: "browserMinimumMiB") as? Double
            ?? legacyRules?.minimumMiB ?? 2)
        browserExcludedHosts = defaults.string(forKey: "browserExcludedHosts")
            ?? legacyRules?.excludedHosts ?? ""
        browserReuseSessionHeaders = defaults.object(forKey: "browserReuseSessionHeaders") as? Bool
            ?? legacyRules?.reuseSessionHeaders ?? false

        do {
            try workspace.prepare()
            lockDescriptor = open(workspace.root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                if lockDescriptor >= 0 { close(lockDescriptor) }
                lockDescriptor = -1
                duplicateInstance = true
                notice = String(localized: "VeloDrop is already running.")
                return
            }
            workspace.expireOldOutcomes()
            persistBrowserRules()
            transfers = workspace.all()
            for var transfer in transfers where transfer.browserTestID != nil {
                if !transfer.state.terminal {
                    transfer.state = .canceled
                    transfer.url = nil
                    save(transfer)
                }
                removeHistory(transfer)
            }
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
            confirmNextIfNeeded()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func persistBrowserRules() {
        guard lockDescriptor >= 0 else { return }
        do {
            let data = try JSONEncoder().encode(browserRules)
            try data.write(to: workspace.root.appendingPathComponent("browser-rules.json"), options: .atomic)
        } catch {
            notice = String(localized: "Couldn’t save the browser rules. \(error.localizedDescription)")
        }
    }

    func testBrowser(_ browser: SupportedBrowser) {
        guard lockDescriptor >= 0, testingBrowser == nil else { return }
        let id = UUID()
        browserTestErrors[browser.id] = nil
        do {
            let server = try BrowserTestServer(id: id)
            browserTestServer = server
            browserTestID = id
            testingBrowser = browser.id
            server.start { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.browserTestID == id else { return }
                    do {
                        let url = try result.get()
                        let test = BrowserTest(id: id, url: url, expiresAt: Date().addingTimeInterval(30))
                        try self.workspace.setBrowserTest(browser.id, test: test)
                        browser.open(url, activates: false)
                    } catch {
                        self.finishBrowserTest(error: error.localizedDescription)
                    }
                }
            }
            browserTestTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.browserTestID == id else { return }
                self.finishBrowserTest(error: String(localized: "No test download was received. Check the extension in this browser and try again."))
            }
        } catch {
            browserTestErrors[browser.id] = error.localizedDescription
        }
    }

    private func finishBrowserTest(error: String? = nil) {
        guard let browser = testingBrowser else { return }
        let testID = browserTestID
        browserTestErrors[browser] = error
        testingBrowser = nil
        browserTestID = nil
        browserTestServer?.stop()
        browserTestServer = nil
        browserTestTimeout?.cancel()
        browserTestTimeout = nil
        try? workspace.setBrowserTest(browser, test: nil)
        if let testID, error != nil {
            for transfer in transfers where transfer.browserTestID == testID {
                cancel(transfer)
                if let canceled = workspace.read(transfer.id) { removeHistory(canceled) }
            }
        }
    }

    var userTransfers: [Transfer] { transfers.filter { $0.browserTestID == nil } }
    var activeCount: Int { userTransfers.filter { $0.state.running }.count }
    var rate: Int64 { userTransfers.reduce(0) { $0 + $1.speed } }

    func add(_ text: String) throws {
        guard lockDescriptor >= 0, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              Transfer.supports(url) else { throw TransferError.invalidURL }
        var transfer = try Transfer(url: url)
        transfer.destinationPath = defaultFolder
        transfer.existingFilePolicy = existingFilePolicy
        try workspace.update(transfer)
        transfers.insert(transfer, at: 0)
        startLoop()
    }

    func addLinks(_ text: String) throws {
        let links = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !links.isEmpty, links.allSatisfy({ URL(string: $0).map(Transfer.supports) == true }) else {
            throw TransferError.invalidURL
        }
        for link in links { try add(link) }
    }

    func pause(_ transfer: Transfer) { change(transfer.id, to: .paused) }
    func resume(_ transfer: Transfer) { change(transfer.id, to: .queued) }
    func cancel(_ transfer: Transfer) {
        guard change(transfer.id, to: .canceled) else { return }
        if confirmation?.id == transfer.id {
            confirmation = nil
            confirmNextIfNeeded()
        }
    }

    func useBrowser(_ transfer: Transfer) {
        let message = transfer.sourceBrowser.map { String(localized: "Sent back to \($0.name).") }
            ?? String(localized: "Sent back to the browser.")
        guard change(transfer.id, to: .handedToBrowser, message: message) else { return }
        if confirmation?.id == transfer.id {
            confirmation = nil
            confirmNextIfNeeded()
        }
        if confirmation == nil, let browser = transfer.sourceBrowser {
            NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier)
                .first?.activate()
        }
    }

    func showPendingIntake() {
        if shouldShowIntake, let onBrowserIntake {
            shouldShowIntake = false
            onBrowserIntake()
        }
        if !pendingTerminalIDs.isEmpty, let onTerminalIntake {
            terminalSelection = pendingTerminalIDs
            selectedDownloads = Set(pendingTerminalIDs)
            pendingTerminalIDs.removeAll()
            onTerminalIntake()
        }
    }

    func clearTerminalSelection(_ ids: [UUID]) {
        if terminalSelection == ids { terminalSelection.removeAll() }
    }

    func askToConfirm(_ transfer: Transfer) {
        guard let current = transfers.first(where: { $0.id == transfer.id }),
              current.state == .awaitingConfirmation else { return }
        confirmation = current
        showPendingIntake()
    }

    func confirmNextIfNeeded() {
        guard confirmation == nil, let pending = transfers.last(where: { $0.state == .awaitingConfirmation }) else { return }
        confirmation = pending
    }

    func confirm(_ transfer: Transfer, into directory: URL, connections: Int, name: String? = nil, later: Bool = false, filePolicy: ExistingFilePolicy? = nil) {
        guard var item = transfers.first(where: { $0.id == transfer.id }),
              item.state == .awaitingConfirmation else { return }
        item.existingFilePolicy = filePolicy ?? existingFilePolicy
        item.connectionLimit = connections
        if let name { item.name = Transfer.safeName(name) }
        item.destinationPath = directory.standardizedFileURL.path
        let recent = [directory.path] + recentFolders.filter { $0 != directory.path }
        UserDefaults.standard.set(Array(recent.prefix(5)), forKey: "recentFolders")
        item.state = later ? .paused : .queued
        guard save(item) else { return }
        if confirmation?.id == item.id { confirmation = nil }
        if !later { onProgress?(item.id) }
        confirmNextIfNeeded()
        startLoop()
    }

    func setConnections(_ id: UUID, count: Int) {
        guard (1...16).contains(count),
              var item = transfers.first(where: { $0.id == id }), !item.state.terminal else { return }
        item.connectionLimit = count
        save(item)
        startLoop()
    }

    func setSpeed(_ id: UUID, bytesPerSecond: Int64) {
        guard var item = transfers.first(where: { $0.id == id }), !item.state.terminal else { return }
        item.speedLimit = max(0, bytesPerSecond)
        save(item)
    }

    func setPriority(_ id: UUID, priority: Int) {
        guard var item = transfers.first(where: { $0.id == id }), !item.state.terminal else { return }
        item.priority = priority
        save(item)
        Task { try? await engine.prioritize(id, first: priority > 0) }
    }

    func delete(_ ids: Set<UUID>, files: Bool) async {
        for id in ids {
            guard let item = transfers.first(where: { $0.id == id }) else { continue }
            if !item.state.terminal { cancel(item) }
            await engine.remove(id)
            guard let current = transfers.first(where: { $0.id == id }) else { continue }
            if files && deletableFileSize(current) != nil { trash(current) }
            else { removeHistory(current) }
        }
    }

    func deletableFileSize(_ transfer: Transfer) -> Int64? {
        guard transfer.state == .completed, let path = transfer.finalPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard workspace.ownsPublishedFile(url, id: transfer.id),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    func reveal(_ transfer: Transfer) {
        if let path = transfer.finalPath {
            guard FileManager.default.fileExists(atPath: path) else {
                notice = String(localized: "The original downloaded file is no longer at this location.")
                return
            }
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

    private func trash(_ transfer: Transfer) {
        guard transfer.state == .completed, let path = transfer.finalPath else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            removeHistory(transfer)
            return
        }
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
        browserTestServer?.stop()
        browserTestTimeout?.cancel()
        if let testingBrowser { try? workspace.setBrowserTest(testingBrowser, test: nil) }
        engine.stop()
    }

    @discardableResult
    private func change(_ id: UUID, to state: TransferState, message: String? = nil) -> Bool {
        guard var item = transfers.first(where: { $0.id == id }) else { return false }
        if state == .queued, item.url == nil { return false }
        if state == .paused, !item.state.running { return false }
        if state == .canceled, item.state.terminal { return false }
        if state == .failed || state == .handedToBrowser, item.state.terminal { return false }
        item.state = state
        item.message = message
        item.speed = 0
        item.connections = 0
        item.finishedAt = state.terminal ? Date() : nil
        if state.terminal { browserHeaders.removeValue(forKey: id) }
        if state == .canceled || state == .handedToBrowser || (state == .failed && item.fromBrowser) { item.url = nil }
        guard save(item) else { return false }
        startLoop()
        return true
    }

    @discardableResult
    private func save(_ transfer: Transfer, refreshUI: Bool = true) -> Bool {
        var updated = transfer
        updated.updatedAt = Date()
        do {
            try workspace.update(updated)
            guard refreshUI else { return true }
            if let index = transfers.firstIndex(where: { $0.id == updated.id }) {
                transfers[index] = updated
            } else {
                transfers.insert(updated, at: 0)
            }
            return true
        } catch {
            notice = String(localized: "Couldn’t save the download state. \(error.localizedDescription)")
            return false
        }
    }

    private func drainInbox() {
        for (path, var transfer, headers) in workspace.incoming() {
            if workspace.status(transfer.id) == nil && !workspace.wasAbandoned(transfer.id) {
                let isTest = transfer.browserTestID != nil
                if isTest && transfer.browserTestID != browserTestID {
                    changeOrRejectTest(transfer)
                    try? FileManager.default.removeItem(at: path)
                    continue
                }
                transfer.destinationPath = defaultFolder
                transfer.existingFilePolicy = existingFilePolicy
                if !isTest && confirmBrowserDownloads && transfer.fromBrowser {
                    transfer.state = .awaitingConfirmation
                }
                save(transfer)
                if transfers.contains(where: { $0.id == transfer.id }) {
                    if !headers.fields.isEmpty { browserHeaders[transfer.id] = headers }
                    if transfer.state == .awaitingConfirmation && confirmation == nil {
                        confirmation = transfer
                    }
                    if !isTest && transfer.fromBrowser && (showWindowOnCapture || transfer.state == .awaitingConfirmation) {
                        shouldShowIntake = true
                    }
                }
            }
            try? FileManager.default.removeItem(at: path)
        }
        drainTerminalSubmissions()
        showPendingIntake()
        startLoop()
    }

    private func drainTerminalSubmissions() {
        for (path, submission) in workspace.terminalSubmissions() {
            var accepted = true
            for var transfer in submission.transfers where workspace.status(transfer.id) == nil {
                transfer.submittedFromTerminal = true
                transfer.destinationPath = transfer.destinationPath ?? defaultFolder
                transfer.existingFilePolicy = .rename
                if !save(transfer) { accepted = false }
            }
            // A batch survives an interruption during intake. The next pass
            // skips the tasks that already have records.
            guard accepted else { continue }
            do {
                try FileManager.default.removeItem(at: path)
                if submission.showWindow { pendingTerminalIDs.append(contentsOf: submission.transfers.map(\.id)) }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func changeOrRejectTest(_ transfer: Transfer) {
        var canceled = transfer
        canceled.state = .canceled
        canceled.url = nil
        if save(canceled) { removeHistory(canceled) }
    }

    private func attach(_ transfer: Transfer) async throws {
        var item = transfer
        if item.existingFilePolicy == .skip && FileManager.default.fileExists(atPath: workspace.directory(for: item).appendingPathComponent(item.name).path) {
            change(item.id, to: .canceled, message: TransferError.fileExists.localizedDescription)
            return
        }
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
                if confirmation?.id == item.id {
                    confirmation = nil
                    confirmNextIfNeeded()
                }
            }

            let stale = engine.attached.filter { id in transfers.first { $0.id == id }?.state.terminal ?? true }
            for id in stale {
                await engine.remove(id)
            }
            for item in transfers where item.state == .canceled || item.state == .handedToBrowser || (item.fromBrowser && item.state == .failed) {
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
                try await engine.configureGlobal(concurrent: simultaneousDownloads, speed: bandwidthLimit)
                for item in transfers where engine.attached.contains(item.id) && !item.state.terminal {
                    try await engine.configure(item.id, connections: item.connectionLimit ?? maxConnections,
                                               resume: item.state.running)
                    try await engine.setSpeed(item.id, bytesPerSecond: item.speedLimit ?? 0)
                }
                let statuses = try await engine.statuses(Array(engine.attached))
                for item in paused {
                    if statuses[item.id]?.status == "complete" { await update(item.id, with: statuses[item.id]); continue }
                    if let status = statuses[item.id], status.status == "active" || status.status == "waiting" {
                        try await engine.pause(item.id)
                    }
                }
                for item in running.sorted(by: {
                    if ($0.priority ?? 0) != ($1.priority ?? 0) { return ($0.priority ?? 0) > ($1.priority ?? 0) }
                    return $0.createdAt < $1.createdAt
                }) {
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
        if UserDefaults.standard.bool(forKey: "playCompletionSound") { NSSound(named: "Glass")?.play() }
        browserHeaders.removeValue(forKey: completed.id)
        save(completed)
        if workspace.read(transfer.id)?.state == .completed {
            try? FileManager.default.removeItem(at: workspace.stage(transfer.id))
        }
    }

    private func completeBrowserTest(_ item: Transfer) {
        let payload = workspace.stage(item.id).appendingPathComponent("payload")
        let size = (try? payload.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard item.browserTestID == browserTestID else {
            cancel(item)
            if let canceled = workspace.read(item.id) { removeHistory(canceled) }
            return
        }
        guard let browser = item.sourceBrowser, size == BrowserTest.bytes else {
            change(item.id, to: .failed, message: String(localized: "The test file did not match the expected size."))
            finishBrowserTest(error: String(localized: "The test file did not match the expected size."))
            return
        }
        do {
            var completed = item
            completed.state = .completed
            completed.url = nil
            completed.speed = 0
            completed.finishedAt = Date()
            guard save(completed) else { throw TransferError.invalidResponse }
            try workspace.noteBrowserTestPassed(browser,
                extensionVersion: workspace.browserConnection(browser)?.extensionVersion)
            removeHistory(completed)
            finishBrowserTest()
        } catch {
            finishBrowserTest(error: error.localizedDescription)
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
                } else if item.browserTestID != nil {
                    completeBrowserTest(item)
                } else {
                    finish(item, at: try workspace.publish(item))
                }
            } catch TransferError.fileExists {
                change(id, to: .canceled, message: TransferError.fileExists.localizedDescription)
            } catch {
                change(id, to: .failed, message: error.localizedDescription)
            }
            await engine.forget(id)
        case "error", "removed":
            change(id, to: .failed, message: status.explanation)
            if let testID = item.browserTestID, testID == browserTestID {
                finishBrowserTest(error: status.explanation)
            }
            await engine.forget(id)
        case "waiting":
            guard item.state != .paused else { return }
            item.state = .queued
            item.speed = 0
            item.connections = 0
            if let old = transfers.first(where: { $0.id == id }), item != old { save(item) }
        case "active":
            guard item.state != .paused else { return }
            item.state = .downloading
            if let old = transfers.first(where: { $0.id == id }), item != old { save(item) }
        default: break
        }
    }
}
