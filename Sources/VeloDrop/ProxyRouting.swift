import CFNetwork
import Foundation
import VeloCore

enum ProxyRouting {
    static func route(_ requested: BrowserProxy?, for url: URL) throws -> BrowserProxy {
        if let requested, requested.mode != .system { return requested }
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]],
              let first = proxies.first else { return .direct }
        let type = first[kCFProxyTypeKey as String] as? String
        if type == kCFProxyTypeNone as String { return .direct }
        if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String {
            var parts = URLComponents()
            parts.scheme = "http"
            let host = first[kCFProxyHostNameKey as String] as? String
            parts.host = (host?.contains(":") == true && host?.hasPrefix("[") == false)
                ? host.map { "[" + $0 + "]" } : host
            parts.port = first[kCFProxyPortNumberKey as String] as? Int
            if let endpoint = parts.url, let proxy = BrowserProxy.http(endpoint) { return proxy }
        }
        throw TransferError.engine(String(localized: "This proxy route needs to be handled by Edge."))
    }
}
