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
    var source: URL?
    var referrer: URL?
    var mimeType: String?
    var headers: [String: String]?
    var proxy: BrowserProxy?
}

private struct Reply: Encodable {
    let ok: Bool
    var jobs: [String: Workspace.BrowserStatus]?
    var appRunning: Bool?
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
        var transfer = try Transfer(id: id, url: url, name: name, fromBrowser: true,
                                    expectedBytes: request.size.flatMap { $0 > 0 ? $0 : nil })
        let headers = BrowserHeaders(request.headers ?? [:])
        transfer.sourceURL = Transfer.displayURL(request.source ?? url)
        transfer.referringPage = Transfer.displayURL(request.referrer)
        transfer.mimeType = request.mimeType.map { String($0.prefix(128)) }
        transfer.browserHeaderNames = request.headers.map { _ in headers.fields.keys.sorted() }
        transfer.requiresBrowserSession = headers.requiresSession
        if let proxy = request.proxy, proxy.mode == .fixed {
            guard let endpoint = proxy.endpoint, let verified = BrowserProxy.http(endpoint) else {
                return Reply(ok: false)
            }
            transfer.browserProxy = verified
        } else {
            transfer.browserProxy = request.proxy?.mode == .direct ? .direct : .system
        }
        try workspace.submit(transfer, headers: headers)
        do { try launch(bundle) }
        catch {
            try? workspace.abandon(id)
            return Reply(ok: false)
        }
        return Reply(ok: true)

    case "status":
        var statuses: [String: Workspace.BrowserStatus] = [:]
        for value in (request.ids ?? []).prefix(192) {
            if let id = UUID(uuidString: value), let status = workspace.browserStatus(id) {
                statuses[value] = status
            }
        }
        return Reply(ok: true, jobs: statuses, appRunning: workspace.appIsRunning)

    case "acknowledge":
        guard let id = request.id else { return Reply(ok: false) }
        workspace.acknowledge(id)
        return Reply(ok: true)

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
    let identifier = Bundle(url: bundle)?.bundleIdentifier ?? BundleLayout.identifier
    if !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let environment = ProcessInfo.processInfo.environment
    let dataOverrides = ["VELODROP_DATA", "VELODROP_DESTINATION"].flatMap { key in
        environment[key].map { ["--env", "\(key)=\($0)"] } ?? []
    }
    process.arguments = ["-g", "-a", bundle.path, "--env", "VELODROP_BACKGROUND_LAUNCH=1"] + dataOverrides
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
