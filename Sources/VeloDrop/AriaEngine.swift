import Foundation
import VeloCore

struct EngineStatus: Decodable {
    let status: String
    let totalLength: String?
    let completedLength: String?
    let downloadSpeed: String?
    let connections: String?
    let errorCode: String?

    var total: Int64 { Int64(totalLength ?? "") ?? 0 }
    var received: Int64 { Int64(completedLength ?? "") ?? 0 }
    var speed: Int64 { Int64(downloadSpeed ?? "") ?? 0 }
    var peers: Int { Int(connections ?? "") ?? 0 }

    var explanation: String {
        switch errorCode {
        case "2": return String(localized: "The server timed out.")
        case "3": return String(localized: "The file is unavailable or requires a browser session.")
        case "9": return String(localized: "The disk is out of space.")
        case "12", "13", "14": return String(localized: "The partial file could not be resumed.")
        case "22": return String(localized: "The server returned an unexpected response.")
        case "24": return String(localized: "The server rejected this download.")
        default: return String(localized: "The download failed. You can retry it.")
        }
    }
}

@MainActor
final class AriaEngine {
    private let executable: URL
    private let workingDirectory: URL
    private let session: URLSession
    private var process: Process?
    private var endpoint: URL?
    private var secret = ""
    private(set) var attached = Set<UUID>()
    private var limits: [UUID: Int] = [:]
    private var speeds: [UUID: Int64] = [:]
    private var globalConfiguration = ""

    init(executable: URL, workingDirectory: URL) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                                   "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        self.session = URLSession(configuration: configuration)
    }

    func start() async throws {
        if process?.isRunning == true { return }
        attached.removeAll()
        limits.removeAll()
        speeds.removeAll()
        globalConfiguration = ""
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TransferError.engineUnavailable
        }
        let port = Int.random(in: 49152...65535)
        endpoint = URL(string: "http://127.0.0.1:\(port)/jsonrpc")
        secret = UUID().uuidString + UUID().uuidString

        let child = Process()
        child.executableURL = executable
        child.currentDirectoryURL = workingDirectory
        child.arguments = [
            "--no-conf=true", "--no-netrc=true", "--enable-rpc=true",
            "--rpc-listen-all=false", "--rpc-listen-port=\(port)", "--rpc-secret=\(secret)",
            "--disable-ipv6=true", "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
            "--max-concurrent-downloads=3", "--auto-save-interval=1",
            "--summary-interval=0", "--console-log-level=error",
        ]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        for _ in 0..<15 {
            guard child.isRunning else { break }
            if let _: Version = try? await call("aria2.getVersion", []) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        throw TransferError.engineUnavailable
    }

    func stop() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
        endpoint = nil
        attached.removeAll()
        limits.removeAll()
        speeds.removeAll()
        globalConfiguration = ""
    }

    func add(_ transfer: Transfer, stage: URL, connections: Int, headers: BrowserHeaders?) async throws {
        guard let url = transfer.url, Transfer.supports(url) else { throw TransferError.invalidURL }
        if attached.contains(transfer.id) {
            let _: String = try await call("aria2.unpause", [gid(transfer.id)])
        } else {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let proxy = transfer.effectiveProxy ?? .direct
            let address = proxy.endpoint?.absoluteString ?? ""
            var options: [String: Any] = [
                "gid": gid(transfer.id), "dir": stage.path, "out": "payload",
                "max-download-limit": String(transfer.speedLimit ?? 0),
                "split": String(connections), "max-connection-per-server": String(connections),
                "min-split-size": "4M", "file-allocation": "none",
                "continue": "true", "always-resume": "true", "stream-piece-selector": "inorder",
                "auto-file-renaming": "false", "allow-overwrite": "false",
                "check-certificate": "true", "http-accept-gzip": "false",
                "max-tries": "3", "retry-wait": "2", "connect-timeout": "8", "timeout": "15",
                "http-proxy": address, "https-proxy": address, "all-proxy": address, "no-proxy": "",
            ]
            if let fields = headers?.fields, !fields.isEmpty {
                options["header"] = ["X-VeloDrop-Request-URL: " + url.absoluteString]
                    + fields.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }
            }
            let _: String = try await call("aria2.addUri", [[url.absoluteString], options])
            attached.insert(transfer.id)
            limits[transfer.id] = connections
        }
    }

    func configure(_ id: UUID, connections: Int, resume: Bool) async throws {
        guard attached.contains(id), limits[id] != connections else { return }
        try await pause(id)
        let _: String = try await call("aria2.changeOption", [gid(id), [
            "split": String(connections), "max-connection-per-server": String(connections)
        ]])
        limits[id] = connections
        if resume {
            let _: String = try await call("aria2.unpause", [gid(id)])
        }
    }

    func configureGlobal(concurrent: Int, speed: Int64) async throws {
        let configuration = "\(concurrent)-\(speed)"
        guard configuration != globalConfiguration else { return }
        let _: String = try await call("aria2.changeGlobalOption", [[
            "max-concurrent-downloads": String(concurrent),
            "max-overall-download-limit": String(speed)
        ]])
        globalConfiguration = configuration
    }

    func setSpeed(_ id: UUID, bytesPerSecond: Int64) async throws {
        guard attached.contains(id), speeds[id] != bytesPerSecond else { return }
        let _: String = try await call("aria2.changeOption", [gid(id), ["max-download-limit": String(bytesPerSecond)]])
        speeds[id] = bytesPerSecond
    }

    func prioritize(_ id: UUID, first: Bool) async throws {
        guard attached.contains(id) else { return }
        let _: Int = try await call("aria2.changePosition", [gid(id), first ? 0 : 10000, "POS_SET"])
    }

    func statuses(_ ids: [UUID]) async throws -> [UUID: EngineStatus] {
        guard !ids.isEmpty else { return [:] }
        let properties = ["status", "totalLength", "completedLength", "downloadSpeed", "connections", "errorCode"]
        let calls: [[String: Any]] = ids.map { request("aria2.tellStatus", [gid($0), properties], id: $0.uuidString) }
        let data = try await post(calls)
        let replies = try JSONDecoder().decode([RPCReply<EngineStatus>].self, from: data)
        return Dictionary(uniqueKeysWithValues: replies.compactMap { reply in
            guard let id = UUID(uuidString: reply.id), let status = reply.result else { return nil }
            return (id, status)
        })
    }

    func pause(_ id: UUID) async throws {
        guard attached.contains(id) else { return }
        let _: String = try await call("aria2.forcePause", [gid(id)])
    }

    func remove(_ id: UUID) async {
        limits.removeValue(forKey: id)
        guard attached.remove(id) != nil else { return }
        let _: String? = try? await call("aria2.forceRemove", [gid(id)])
        let _: String? = try? await call("aria2.removeDownloadResult", [gid(id)])
    }

    func forget(_ id: UUID) async {
        attached.remove(id)
        limits.removeValue(forKey: id)
        let _: String? = try? await call("aria2.removeDownloadResult", [gid(id)])
    }

    private func gid(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
    }

    private func request(_ method: String, _ parameters: [Any], id: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": ["token:" + secret] + parameters]
    }

    private func post(_ body: Any) async throws -> Data {
        guard let endpoint, process?.isRunning == true else { throw TransferError.engineUnavailable }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        return data
    }

    private func call<Result: Decodable>(_ method: String, _ parameters: [Any]) async throws -> Result {
        let data = try await post(request(method, parameters, id: "velodrop"))
        let reply = try JSONDecoder().decode(RPCReply<Result>.self, from: data)
        guard let result = reply.result else { throw TransferError.invalidResponse }
        return result
    }

    private struct Version: Decodable { let version: String }
    private struct RPCReply<Result: Decodable>: Decodable {
        let id: String
        let result: Result?
    }
}
