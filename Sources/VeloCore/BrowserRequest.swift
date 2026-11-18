import Foundation

public struct BrowserProxy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case system, direct, fixed }
    public var mode: Mode
    public var endpoint: URL?

    public static let system = Self(mode: .system)
    public static let direct = Self(mode: .direct)

    public static func http(_ url: URL) -> Self? {
        guard Transfer.supports(url), url.scheme == "http", let port = url.port,
              (1...65535).contains(port), url.path.isEmpty || url.path == "/",
              url.query == nil, url.fragment == nil else { return nil }
        return Self(mode: .fixed, endpoint: url)
    }
}

public struct BrowserHeaders: Codable, Equatable, Sendable {
    public let fields: [String: String]

    public init(_ input: [String: String]) {
        let names = ["accept": "Accept", "accept-language": "Accept-Language", "user-agent": "User-Agent",
                     "referer": "Referer", "cookie": "Cookie", "authorization": "Authorization"]
        var fields: [String: String] = [:]
        for (key, value) in input {
            guard let name = names[key.lowercased()], (1...8192).contains(value.utf8.count),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
            fields[name] = value
        }
        self.fields = fields
    }

    public var requiresSession: Bool { fields["Cookie"] != nil || fields["Authorization"] != nil }
}
