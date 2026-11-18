import Foundation

public enum BundleLayout {
    public static let identifier = "com.amayakite.velodrop"
    public static func engine(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/Helpers/aria2c") }
    public static func bridge(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/Helpers/VeloBridge") }
    public static func browserExtension(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/EdgeExtension", isDirectory: true)
    }
}
