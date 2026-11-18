import Foundation

public struct BrowserRules: Codable, Sendable {
    public let enabled: Bool
    public let minimumMiB: Double
    public let excludedHosts: String
}
