import Foundation
import Network
import VeloCore

/// Serves one temporary attachment on localhost for a test started in Settings.
final class BrowserTestServer {
    private let listener: NWListener
    private let filename: String
    private let queue = DispatchQueue(label: "com.amayakite.velodrop.browser-test")

    init(id: UUID) throws {
        filename = "VeloDrop-Test-\(id.uuidString).txt"
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(onReady: @escaping (Result<URL, Error>) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port?.rawValue,
                   let url = URL(string: "http://127.0.0.1:\(port)/\(self.filename)") {
                    onReady(.success(url))
                } else {
                    onReady(.failure(TransferError.invalidResponse))
                }
            case .failed(let error):
                onReady(.failure(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(from: connection)
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func receive(from connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            let bytes = buffer + data
            guard bytes.count <= 8192 else { connection.cancel(); return }
            guard let end = bytes.range(of: Data("\r\n".utf8)) else {
                if complete { connection.cancel() }
                else { self.receive(from: connection, buffer: bytes) }
                return
            }
            let line = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[1] == "/" + self.filename else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                + "Content-Disposition: attachment; filename=\"\(self.filename)\"\r\n"
                + "Content-Length: \(BrowserTest.bytes)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            let firstLine = Data("VeloDrop browser connection test\n".utf8)
            connection.send(content: Data(header.utf8) + firstLine, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { connection.cancel(); return }
                self.sendBody(to: connection, remaining: BrowserTest.bytes - firstLine.count)
            })
        }
    }

    private func sendBody(to connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { connection.cancel(); return }
        let count = min(remaining, 128 * 1024)
        connection.send(content: Data(repeating: 32, count: count), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            // Give the browser time to report and hand off the attachment even over loopback.
            self.queue.asyncAfter(deadline: .now() + .milliseconds(65)) { [weak self] in
                guard let self else { connection.cancel(); return }
                self.sendBody(to: connection, remaining: remaining - count)
            }
        })
    }
}
