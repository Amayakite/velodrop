import Foundation

public enum BrowserID: String, Codable, CaseIterable, Sendable {
    case chrome, edge, brave, vivaldi, firefox

    public var name: String {
        switch self {
        case .chrome: "Chrome"
        case .edge: "Edge"
        case .brave: "Brave"
        case .vivaldi: "Vivaldi"
        case .firefox: "Firefox"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .firefox: "org.mozilla.firefox"
        }
    }

    public init?(bundleIdentifier: String) {
        guard let match = Self.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        self = match
    }
}

public struct BrowserConnection: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let extensionVersion: String?

    public init(checkedAt: Date = Date(), extensionVersion: String?) {
        self.checkedAt = checkedAt
        self.extensionVersion = extensionVersion
    }
}

public struct BrowserTest: Codable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let expiresAt: Date
    public static let bytes = 3 * 1024 * 1024

    public init(id: UUID, url: URL, expiresAt: Date) {
        self.id = id
        self.url = url
        self.expiresAt = expiresAt
    }
}
