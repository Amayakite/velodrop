import Foundation

public struct BrowserRules: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var minimumMiB: Double
    public var excludedHosts: String
    public var reuseSessionHeaders: Bool

    public init(enabled: Bool = true, minimumMiB: Double = 2,
                excludedHosts: String = "", reuseSessionHeaders: Bool = false) {
        self.enabled = enabled
        self.minimumMiB = minimumMiB
        self.excludedHosts = excludedHosts
        self.reuseSessionHeaders = reuseSessionHeaders
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, minimumMiB, excludedHosts, reuseSessionHeaders
    }

    // Settings written by VeloDrop 0.5 and earlier do not contain the session
    // header preference. Keep those files readable while the app migrates them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        minimumMiB = try container.decodeIfPresent(Double.self, forKey: .minimumMiB) ?? 2
        excludedHosts = try container.decodeIfPresent(String.self, forKey: .excludedHosts) ?? ""
        reuseSessionHeaders = try container.decodeIfPresent(Bool.self, forKey: .reuseSessionHeaders) ?? false
    }
}
