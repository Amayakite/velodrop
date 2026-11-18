import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func render(_ size: Int, to url: URL) throws {
    let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: pixels)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let tile = NSBezierPath(roundedRect: NSRect(x: 99, y: 107, width: 826, height: 826), xRadius: 181, yRadius: 181)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.29, blue: 0.86, alpha: 1),
                              ending: NSColor(srgbRed: 0.25, green: 0.65, blue: 1, alpha: 1))!
    gradient.draw(in: tile, angle: 105)
    NSColor.white.withAlphaComponent(0.13).setStroke()
    tile.lineWidth = 6
    tile.stroke()

    func path(_ points: [(CGFloat, CGFloat)], width: CGFloat, opacity: CGFloat = 1) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() { line.line(to: NSPoint(x: point.0, y: point.1)) }
        line.lineWidth = width
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(opacity).setStroke()
        line.stroke()
    }

    path([(294, 351), (294, 289), (730, 289), (730, 351)], width: 52, opacity: 0.52)
    path([(512, 746), (512, 446), (390, 567)], width: 63)
    path([(512, 446), (634, 567)], width: 63)
    path([(344, 684), (344, 630)], width: 29, opacity: 0.39)
    path([(681, 684), (681, 630)], width: 29, opacity: 0.39)
    NSGraphicsContext.restoreGraphicsState()

    try pixels.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
for size in [16, 32, 48, 128] {
    try render(size, to: directory.appendingPathComponent("Icon\(size).png"))
}
