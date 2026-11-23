import Foundation

public enum TransferState: String, Codable, Sendable {
    case awaitingConfirmation, queued, downloading, paused, completed, failed, canceled, handedToBrowser

    public var terminal: Bool { self == .completed || self == .failed || self == .canceled || self == .handedToBrowser }
    public var running: Bool { self == .queued || self == .downloading }
}

public enum ExistingFilePolicy: String, Codable, CaseIterable, Sendable {
    case rename, skip, replace
}

public struct Transfer: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var url: URL?
    public var name: String
    public let fromBrowser: Bool
    public var sourceBrowser: BrowserID?
    public var browserTestID: UUID?
    public var submittedFromTerminal: Bool?
    public let expectedBytes: Int64?
    public let createdAt: Date
    public var updatedAt: Date
    public var state: TransferState
    public var received: Int64 = 0
    public var total: Int64 = 0
    public var speed: Int64 = 0
    public var connections: Int = 0
    public var connectionLimit: Int?
    public var finalPath: String?
    public var message: String?
    public var sourceURL: URL?
    public var referringPage: URL?
    public var mimeType: String?
    public var browserHeaderNames: [String]?
    public var requiresBrowserSession: Bool?
    public var browserProxy: BrowserProxy?
    public var effectiveProxy: BrowserProxy?
    public var destinationPath: String?
    public var existingFilePolicy: ExistingFilePolicy?
    public var priority: Int?
    public var speedLimit: Int64?
    public var finishedAt: Date?

    public var displayName: String {
        finalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
    }

    public static func displayURL(_ url: URL?) -> URL? {
        guard let url, supports(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    public init(id: UUID = UUID(), url: URL, name: String, fromBrowser: Bool,
                expectedBytes: Int64? = nil) throws {
        guard Self.supports(url) else { throw TransferError.invalidURL }
        self.id = id
        self.url = url
        self.name = Self.safeName(name)
        self.sourceURL = Self.displayURL(url)
        self.fromBrowser = fromBrowser
        self.expectedBytes = expectedBytes
        self.createdAt = Date()
        self.updatedAt = createdAt
        self.state = .queued
        self.total = expectedBytes ?? 0
    }

    public init(url: URL) throws {
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "Download") : url.lastPathComponent
        try self.init(url: url, name: name, fromBrowser: false)
    }

    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(Double(received) / Double(total), 1)
    }

    public static func supports(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return !(url.host?.isEmpty ?? true) && url.user == nil && url.password == nil
            && url.absoluteString.utf8.count <= 8192
    }

    public static func safeName(_ input: String) -> String {
        let components = input.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let name = components.last.map(String.init) ?? ""
        let visible = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(visible))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var output = ""
        for character in trimmed {
            guard output.utf8.count + String(character).utf8.count <= 200 else { break }
            output.append(character)
        }
        return output.isEmpty ? "Download" : output
    }
}

public enum TransferError: LocalizedError {
    case fileExists, invalidURL, engineUnavailable, invalidResponse, missingFile, unexpectedSize, busy
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .fileExists: return String(localized: "A file with this name already exists. Download skipped.")
        case .invalidURL: return String(localized: "Enter a valid HTTP or HTTPS link.")
        case .engineUnavailable: return String(localized: "The download engine could not start.")
        case .invalidResponse: return String(localized: "The download engine returned an invalid response.")
        case .missingFile: return String(localized: "The download engine did not produce a file.")
        case .unexpectedSize: return String(localized: "The server returned a different file size.")
        case .busy: return String(localized: "A download with that ID is already queued.")
        case .engine(let message): return message
        }
    }
}
