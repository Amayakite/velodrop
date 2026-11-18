import AppKit
import Foundation
import VeloCore

private struct Request: Codable {
    let action: String
    var id: UUID?
    var ids: [String]?
    var url: URL?
    var name: String?
    var size: Int64?
}

private struct Reply: Encodable {
    let ok: Bool
    var jobs: [String: Status]?
}

private struct Status: Encodable {
    let state: TransferState
    let updatedAt: Int64
}

private func handle(_ data: Data, bundle: URL) throws -> Reply {
    let request = try JSONDecoder().decode(Request.self, from: data)
    let workspace = Workspace.standard()
    try workspace.prepare()

    switch request.action {
    case "ping":
        let engine = BundleLayout.engine(in: bundle)
        return Reply(ok: FileManager.default.isExecutableFile(atPath: engine.path))

    case "submit":
        guard let id = request.id, let url = request.url, let name = request.name,
              !workspace.wasAbandoned(id) else { return Reply(ok: false) }
        let transfer = try Transfer(id: id, url: url, name: name, fromBrowser: true,
                                    expectedBytes: request.size.flatMap { $0 > 0 ? $0 : nil })
        try workspace.submit(transfer)
        do { try launch(bundle) }
        catch {
            try? workspace.abandon(id)
            return Reply(ok: false)
        }
        return Reply(ok: true)

    case "status":
        var statuses: [String: Status] = [:]
        for value in (request.ids ?? []).prefix(192) {
            if let id = UUID(uuidString: value), let job = workspace.read(id) {
                statuses[value] = Status(state: job.state,
                                         updatedAt: Int64(job.updatedAt.timeIntervalSince1970 * 1000))
            }
        }
        return Reply(ok: true, jobs: statuses)

    case "abandon":
        guard let id = request.id else { return Reply(ok: false) }
        try workspace.abandon(id)
        return Reply(ok: true)

    default:
        return Reply(ok: false)
    }
}

private func launch(_ bundle: URL) throws {
    if ProcessInfo.processInfo.environment["VELODROP_TEST_NO_LAUNCH"] == "1" { return }
    if !NSRunningApplication.runningApplications(withBundleIdentifier: BundleLayout.identifier).isEmpty { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let environment = ProcessInfo.processInfo.environment
    let dataOverrides = ["VELODROP_DATA", "VELODROP_DESTINATION"].flatMap { key in
        environment[key].map { ["--env", "\(key)=\($0)"] } ?? []
    }
    process.arguments = ["-g", "-a", bundle.path] + dataOverrides
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw TransferError.engineUnavailable }
}

private func exactly(_ length: Int) throws -> Data {
    var bytes = Data()
    while bytes.count < length {
        guard let chunk = try FileHandle.standardInput.read(upToCount: length - bytes.count), !chunk.isEmpty else {
            throw TransferError.invalidResponse
        }
        bytes.append(chunk)
    }
    return bytes
}

private func processMessage() throws {
    let lengthBytes = try exactly(4)
    let length = lengthBytes.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
    guard (1...256_000).contains(length) else { throw TransferError.invalidResponse }
    let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let request = try exactly(length)
    let reply = (try? handle(request, bundle: bundle)) ?? Reply(ok: false)
    let data = try JSONEncoder().encode(reply)
    let prefix = Data((0..<4).map { UInt8(truncatingIfNeeded: data.count >> ($0 * 8)) })
    try FileHandle.standardOutput.write(contentsOf: prefix + data)
}

do { try processMessage() }
catch { exit(1) }
