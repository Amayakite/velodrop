import Foundation

public enum BundleLayout {
    public static let identifier = "com.amayakite.velodrop"
    public static func engine(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/Helpers/aria2c") }
    public static func bridge(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/Helpers/VeloBridge") }
    public static func terminalCommand(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Helpers/VeloDropCLI")
    }
    public static func browserExtension(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/VeloDropExtension", isDirectory: true)
    }
    public static func firefoxExtension(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/VeloDropFirefoxExtension", isDirectory: true)
    }
}
