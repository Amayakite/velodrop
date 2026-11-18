import Darwin
import Foundation

public struct Workspace: Sendable {
    public let root: URL
    public let destination: URL
    public var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    public var records: URL { root.appendingPathComponent("Transfers", isDirectory: true) }
    public var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
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
        for directory in [root, inbox, records, staging, abandons] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    public func submit(_ transfer: Transfer) throws {
        if FileManager.default.fileExists(atPath: recordURL(transfer.id).path) { throw TransferError.busy }
        try JSONEncoder().encode(transfer).write(to: inboxURL(transfer.id), options: .atomic)
    }

    public func update(_ transfer: Transfer) throws {
        try JSONEncoder().encode(transfer).write(to: recordURL(transfer.id), options: .atomic)
    }

    public func read(_ id: UUID) -> Transfer? { readFile(recordURL(id)) }

    public func incoming() -> [(URL, Transfer)] {
        files(in: inbox).compactMap { file in
            guard let transfer = readFile(file), file.lastPathComponent == inboxURL(transfer.id).lastPathComponent else { return nil }
            return (file, transfer)
        }.sorted { $0.1.createdAt < $1.1.createdAt }
    }

    public func all() -> [Transfer] {
        files(in: records).compactMap(readFile).sorted { $0.createdAt > $1.createdAt }
    }

    public func stage(_ id: UUID) -> URL {
        staging.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func abandon(_ id: UUID) throws {
        try Data().write(to: abandons.appendingPathComponent(id.uuidString), options: .atomic)
    }

    public func wasAbandoned(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: abandons.appendingPathComponent(id.uuidString).path)
    }

    public func recoveredOutput(_ id: UUID) -> URL? {
        let stage = stage(id)
        let payload = stage.appendingPathComponent("payload")
        guard !FileManager.default.fileExists(atPath: payload.path),
              let name = try? String(contentsOf: stage.appendingPathComponent("publication"), encoding: .utf8),
              name == (name as NSString).lastPathComponent else { return nil }
        let file = destination.appendingPathComponent(name)
        let value = "com.apple.quarantine"
        let count = getxattr(file.path, value, nil, 0, 0, 0)
        guard (1...1024).contains(count) else { return nil }
        var attribute = Data(count: count)
        let read = attribute.withUnsafeMutableBytes { getxattr(file.path, value, $0.baseAddress, count, 0, 0) }
        guard read == count, String(decoding: attribute, as: UTF8.self).hasSuffix(";" + id.uuidString) else {
            return nil
        }
        return file
    }

    public func publish(_ transfer: Transfer) throws -> URL {
        if let existing = recoveredOutput(transfer.id) { return existing }
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

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
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
                continue
            }
        }
        throw TransferError.engine("Couldn’t find an unused filename.")
    }

    private func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles)) ?? []
    }

    private func inboxURL(_ id: UUID) -> URL { inbox.appendingPathComponent(id.uuidString + ".json") }
    private func recordURL(_ id: UUID) -> URL { records.appendingPathComponent(id.uuidString + ".json") }
    private func readFile(_ file: URL) -> Transfer? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Transfer.self, from: data)
    }
}
