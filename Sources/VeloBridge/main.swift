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
    var rules: BrowserRules?
    var version: String?
}

private func handle(_ data: Data, bundle: URL) throws -> Reply {
    let request = try JSONDecoder().decode(Request.self, from: data)
    let workspace = Workspace.standard()
    try workspace.prepare()

    switch request.action {
    case "ping", "rules":
        if request.action == "ping" {
            try Data(String(Date().timeIntervalSince1970).utf8)
                .write(to: workspace.root.appendingPathComponent("browser-connection"), options: .atomic)
        }
        let engine = BundleLayout.engine(in: bundle)
        return Reply(ok: FileManager.default.isExecutableFile(atPath: engine.path),
                     appRunning: workspace.appIsRunning,
                     rules: currentRules(in: workspace),
                     version: appVersion(of: bundle))

    case "submit", "reserve":
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
        if request.action == "reserve" {
            workspace.expireReservations()
            try workspace.submit(transfer, headers: headers, reserve: true)
            return Reply(ok: true)
        }
        try workspace.submit(transfer, headers: headers)
        do { try launch(bundle) }
        catch {
            try? workspace.abandon(id)
            return Reply(ok: false)
        }
        return Reply(ok: true)

    case "activate":
        guard let id = request.id else { return Reply(ok: false) }
        try workspace.activate(id)
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

    case "open":
        // Write the flag for a copy that is still launching, and notify a copy
        // that is already running. The app consumes and removes the flag in both
        // paths, so it cannot leak into an unrelated launch.
        try? Data().write(to: workspace.root.appendingPathComponent("open-settings"), options: .atomic)
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.amayakite.velodrop.openSettings"), object: nil, userInfo: nil)
        do { try launch(bundle, background: false) }
        catch { return Reply(ok: false) }
        return Reply(ok: true)

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

private func currentRules(in workspace: Workspace) -> BrowserRules {
    guard let data = try? Data(contentsOf: workspace.root.appendingPathComponent("browser-rules.json")),
          let rules = try? JSONDecoder().decode(BrowserRules.self, from: data) else {
        return BrowserRules()
    }
    return rules
}

private func appVersion(of bundle: URL) -> String? {
    Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
}

private func launch(_ bundle: URL, background: Bool = true) throws {
    if ProcessInfo.processInfo.environment["VELODROP_TEST_NO_LAUNCH"] == "1" { return }
    let identifier = Bundle(url: bundle)?.bundleIdentifier ?? BundleLayout.identifier
    if !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
        // The app decides when a capture should take focus. Activating here
        // would pull Edge to the background for every ordinary download.
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let environment = ProcessInfo.processInfo.environment
    let dataOverrides = ["VELODROP_DATA", "VELODROP_DESTINATION"].flatMap { key in
        environment[key].map { ["--env", "\(key)=\($0)"] } ?? []
    }
    var args = ["-a", bundle.path]
    if background { args += ["--env", "VELODROP_BACKGROUND_LAUNCH=1"] }
    process.arguments = args + dataOverrides
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

private func processMessages() throws {
    let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    while let prefix = try FileHandle.standardInput.read(upToCount: 4), !prefix.isEmpty {
        let lengthBytes = prefix + (prefix.count < 4 ? try exactly(4 - prefix.count) : Data())
        let length = lengthBytes.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard (1...256_000).contains(length) else { throw TransferError.invalidResponse }
        let request = try exactly(length)
        let reply = (try? handle(request, bundle: bundle)) ?? Reply(ok: false)
        let data = try JSONEncoder().encode(reply)
        let prefix = Data((0..<4).map { UInt8(truncatingIfNeeded: data.count >> ($0 * 8)) })
        try FileHandle.standardOutput.write(contentsOf: prefix + data)
    }
}

do { try processMessages() }
catch { exit(1) }
