import Darwin
import Foundation

public struct TerminalSubmission: Codable, Sendable {
    public let id: UUID
    public let transfers: [Transfer]
    public let showWindow: Bool

    public init(transfers: [Transfer], showWindow: Bool) {
        self.id = UUID()
        self.transfers = transfers
        self.showWindow = showWindow
    }
}

public struct Workspace: Sendable {
    public struct TransferStatus: Codable, Sendable {
        public let state: TransferState
        public let updatedAt: Int64

        init(_ transfer: Transfer) {
            // Older extensions interpret failed as a request to resume Edge.
            state = transfer.state == .handedToBrowser ? .failed : transfer.state
            updatedAt = Int64(transfer.updatedAt.timeIntervalSince1970 * 1000)
        }
    }

    private struct Incoming: Codable {
        let transfer: Transfer
        let fields: [String: String]
    }

    public let root: URL
    public let destination: URL
    public var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    public var records: URL { root.appendingPathComponent("Transfers", isDirectory: true) }
    public var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    private var reservations: URL { root.appendingPathComponent("Reservations", isDirectory: true) }
    private var outcomes: URL { root.appendingPathComponent("Outcomes", isDirectory: true) }
    private var browsers: URL { root.appendingPathComponent("Browsers", isDirectory: true) }
    public var abandons: URL { root.appendingPathComponent("Abandoned", isDirectory: true) }

    public init(root: URL, destination: URL) {
        self.root = root
        self.destination = destination
    }

    public static func standard() -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let root = environment["VELODROP_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Application Support/VeloDrop", isDirectory: true)
        let destination = environment["VELODROP_DESTINATION"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Downloads", isDirectory: true)
        return Self(root: root, destination: destination)
    }

    public func prepare() throws {
        for directory in [root, inbox, records, staging, abandons, outcomes, reservations, browsers] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    public func browserConnection(_ browser: BrowserID) -> BrowserConnection? {
        readBrowserValue(BrowserConnection.self, at: browserFile(browser, suffix: "connection"))
    }

    public func noteBrowserConnection(_ browser: BrowserID, connection: BrowserConnection) throws {
        try JSONEncoder().encode(connection).write(to: browserFile(browser, suffix: "connection"), options: .atomic)
    }

    public func browserTest(_ browser: BrowserID) -> BrowserTest? {
        guard let test = readBrowserValue(BrowserTest.self, at: browserFile(browser, suffix: "pending-test")),
              test.expiresAt > Date() else { return nil }
        return test
    }

    public func setBrowserTest(_ browser: BrowserID, test: BrowserTest?) throws {
        let file = browserFile(browser, suffix: "pending-test")
        if let test {
            try JSONEncoder().encode(test).write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func browserTestResult(_ browser: BrowserID) -> BrowserConnection? {
        readBrowserValue(BrowserConnection.self, at: browserFile(browser, suffix: "test-passed"))
    }

    public func noteBrowserTestPassed(_ browser: BrowserID, extensionVersion: String?) throws {
        let result = BrowserConnection(extensionVersion: extensionVersion)
        try JSONEncoder().encode(result).write(to: browserFile(browser, suffix: "test-passed"), options: .atomic)
    }

    public func removeBrowserConnection(_ browser: BrowserID) {
        for suffix in ["connection", "pending-test", "test-passed"] {
            try? FileManager.default.removeItem(at: browserFile(browser, suffix: suffix))
        }
    }

    private func browserFile(_ browser: BrowserID, suffix: String) -> URL {
        browsers.appendingPathComponent("\(browser.rawValue)-\(suffix).json")
    }

    private func readBrowserValue<Value: Decodable>(_ type: Value.Type, at file: URL) -> Value? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func submit(_ transfer: Transfer, headers: BrowserHeaders? = nil, reserve: Bool = false) throws {
        if status(transfer.id) != nil { throw TransferError.busy }
        let file = reserve ? reservationURL(transfer.id) : inboxURL(transfer.id)
        let data = try JSONEncoder().encode(Incoming(transfer: transfer, fields: headers?.fields ?? [:]))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func activate(_ id: UUID) throws {
        guard !wasAbandoned(id) else { throw TransferError.busy }
        if read(id) != nil || FileManager.default.fileExists(atPath: inboxURL(id).path) { return }
        try FileManager.default.moveItem(at: reservationURL(id), to: inboxURL(id))
    }

    public func submit(_ submission: TerminalSubmission) throws {
        let pending = inbox.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: pending) }
        try JSONEncoder().encode(submission).write(to: pending, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        try FileManager.default.moveItem(at: pending, to: terminalSubmissionURL(submission.id))
    }

    public func update(_ transfer: Transfer) throws {
        try JSONEncoder().encode(transfer).write(to: recordURL(transfer.id), options: .atomic)
    }

    public func read(_ id: UUID) -> Transfer? { readFile(recordURL(id)) }

    public func removeHistory(_ transfer: Transfer) throws {
        if transfer.fromBrowser || transfer.submittedFromTerminal == true {
            let status = try JSONEncoder().encode(TransferStatus(transfer))
            try status.write(to: outcomeURL(transfer.id), options: .atomic)
        }
        try FileManager.default.removeItem(at: recordURL(transfer.id))
    }

    public func status(_ id: UUID) -> TransferStatus? {
        if let transfer = read(id) { return TransferStatus(transfer) }
        guard let data = try? Data(contentsOf: outcomeURL(id)) else { return nil }
        return try? JSONDecoder().decode(TransferStatus.self, from: data)
    }

    public func acknowledge(_ id: UUID) {
        try? FileManager.default.removeItem(at: outcomeURL(id))
    }

    public func expireOldOutcomes() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for file in files(in: outcomes) {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    public func expireReservations() {
        let cutoff = Date().addingTimeInterval(-60)
        for file in files(in: reservations) {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    public var appIsRunning: Bool {
        let descriptor = open(root.appendingPathComponent("app.lock").path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
    }

    public func incoming() -> [(URL, Transfer, BrowserHeaders)] {
        files(in: inbox).compactMap { file in
            guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  let data = try? Data(contentsOf: file) else { return nil }
            let envelope = try? JSONDecoder().decode(Incoming.self, from: data)
            guard let transfer = envelope?.transfer ?? readFile(file),
                  file.lastPathComponent == inboxURL(transfer.id).lastPathComponent else { return nil }
            return (file, transfer, BrowserHeaders(envelope?.fields ?? [:]))
        }.sorted { $0.1.createdAt < $1.1.createdAt }
    }

    public func terminalSubmissions() -> [(URL, TerminalSubmission)] {
        files(in: inbox).compactMap { file in
            guard file.lastPathComponent.hasPrefix("terminal-"),
                  let data = try? Data(contentsOf: file),
                  let submission = try? JSONDecoder().decode(TerminalSubmission.self, from: data),
                  file.lastPathComponent == terminalSubmissionURL(submission.id).lastPathComponent,
                  !submission.transfers.isEmpty,
                  submission.transfers.allSatisfy({ !$0.fromBrowser && $0.state == .queued }) else { return nil }
            return (file, submission)
        }.sorted { $0.1.transfers[0].createdAt < $1.1.transfers[0].createdAt }
    }

    private func terminalSubmissionURL(_ id: UUID) -> URL {
        inbox.appendingPathComponent("terminal-\(id.uuidString).json")
    }

    public func all() -> [Transfer] {
        files(in: records).compactMap(readFile).sorted { $0.createdAt > $1.createdAt }
    }

    public func stage(_ id: UUID) -> URL {
        staging.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func abandon(_ id: UUID) throws {
        try Data().write(to: abandons.appendingPathComponent(id.uuidString), options: .atomic)
        try? FileManager.default.removeItem(at: inboxURL(id))
        try? FileManager.default.removeItem(at: reservationURL(id))
    }

    public func wasAbandoned(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: abandons.appendingPathComponent(id.uuidString).path)
    }

    public func directory(for transfer: Transfer) -> URL {
        guard let path = transfer.destinationPath, path.hasPrefix("/") else { return destination }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public func recoveredOutput(_ transfer: Transfer) -> URL? {
        let id = transfer.id
        let stage = stage(id)
        guard let name = try? String(contentsOf: stage.appendingPathComponent("publication"), encoding: .utf8),
              name == (name as NSString).lastPathComponent else { return nil }
        let file = directory(for: transfer).appendingPathComponent(name)
        return ownsPublishedFile(file, id: id) ? file : nil
    }

    public func ownsPublishedFile(_ file: URL, id: UUID) -> Bool {
        let attributeName = "com.apple.quarantine"
        let count = getxattr(file.path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        guard (1...1024).contains(count) else { return false }
        var attribute = Data(count: count)
        let read = attribute.withUnsafeMutableBytes {
            getxattr(file.path, attributeName, $0.baseAddress, count, 0, XATTR_NOFOLLOW)
        }
        return read == count && String(decoding: attribute, as: UTF8.self).hasSuffix(";" + id.uuidString)
    }

    public func publish(_ transfer: Transfer) throws -> URL {
        if let existing = recoveredOutput(transfer) { return existing }
        let source = stage(transfer.id).appendingPathComponent("payload")
        let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true else { throw TransferError.missingFile }
        if let expected = transfer.expectedBytes, expected > 0, Int64(properties.fileSize ?? -1) != expected {
            throw TransferError.unexpectedSize
        }

        // Preserve Gatekeeper's normal first-open checks for Internet downloads.
        let timestamp = String(Int(Date().timeIntervalSince1970), radix: 16)
        let quarantine = "0081;\(timestamp);VeloDrop;\(transfer.id.uuidString)"
        let result = quarantine.withCString {
            setxattr(source.path, "com.apple.quarantine", $0, strlen($0), 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let destination = directory(for: transfer)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = destination.appendingPathComponent(transfer.name)
        if transfer.existingFilePolicy == .skip && FileManager.default.fileExists(atPath: original.path) {
            throw TransferError.fileExists
        }
        if transfer.existingFilePolicy == .replace && FileManager.default.fileExists(atPath: original.path) {
            let receipt = stage(transfer.id).appendingPathComponent("publication")
            try Data(transfer.name.utf8).write(to: receipt, options: .atomic)
            _ = try FileManager.default.replaceItemAt(original, withItemAt: source, options: .usingNewMetadataOnly)
            return original
        }
        let stem = (transfer.name as NSString).deletingPathExtension
        let ext = (transfer.name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        for index in 1...10_000 {
            let name = index == 1 ? transfer.name : "\(stem) (\(index))\(suffix)"
            let target = destination.appendingPathComponent(name)
            do {
                let receipt = stage(transfer.id).appendingPathComponent("publication")
                try Data(name.utf8).write(to: receipt, options: .atomic)
                try FileManager.default.moveItem(at: source, to: target)
                return target
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteFileExistsError {
                if transfer.existingFilePolicy == .skip { throw TransferError.fileExists }
                // A concurrently created file receives its own name rather than being overwritten.
                continue
            }
        }
        throw TransferError.engine(String(localized: "Couldn’t find an unused filename."))
    }

    private func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles)) ?? []
    }

    private func reservationURL(_ id: UUID) -> URL { reservations.appendingPathComponent(id.uuidString + ".json") }
    private func outcomeURL(_ id: UUID) -> URL { outcomes.appendingPathComponent(id.uuidString + ".json") }
    private func inboxURL(_ id: UUID) -> URL { inbox.appendingPathComponent(id.uuidString + ".json") }
    private func recordURL(_ id: UUID) -> URL { records.appendingPathComponent(id.uuidString + ".json") }
    private func readFile(_ file: URL) -> Transfer? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Transfer.self, from: data)
    }
}
