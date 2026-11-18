import Foundation
import VeloCore

func check(_ condition: Bool, _ line: Int = #line) {
    guard condition else { fatalError("Check failed at line \(line)") }
}

func checkThrows(_ work: () throws -> Void) {
    do {
        try work()
        fatalError("Expected an error")
    } catch {}
}

func checkBrowserInputCannotSetDestinationOrCredentials() throws {
    check(Transfer.safeName("../../some/evil.pkg") == "evil.pkg")
    check(Transfer.safeName("..") == "Download")
    check(!Transfer.supports(URL(string: "file:///tmp/test")!))
    check(!Transfer.supports(URL(string: "https://user:password@example.com/test")!))
}

func checkHandoffAndPublishKeepExistingFileAndQuarantine() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(root: root.appendingPathComponent("state"),
                              destination: root.appendingPathComponent("Downloads"))
    try workspace.prepare()
    let item = try Transfer(url: URL(string: "https://example.com/report.pdf")!,
                            name: "report.pdf", fromBrowser: true, expectedBytes: 5)
    try workspace.submit(item)
    check(workspace.incoming().map(\.1) == [item])
    try workspace.update(item)
    check(workspace.read(item.id) == item)
    checkThrows { try workspace.submit(item) }

    try FileManager.default.createDirectory(at: workspace.destination, withIntermediateDirectories: true)
    let another = workspace.destination.appendingPathComponent(item.name)
    try Data("old".utf8).write(to: another)
    let stage = workspace.stage(item.id)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    let payload = stage.appendingPathComponent("payload")
    try Data("too long".utf8).write(to: payload)
    checkThrows { _ = try workspace.publish(item) }
    try Data("fresh".utf8).write(to: payload)
    let file = try workspace.publish(item)
    check(file.lastPathComponent == "report (2).pdf")
    check(try Data(contentsOf: another) == Data("old".utf8))
    check(try Data(contentsOf: file) == Data("fresh".utf8))
    check(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    check(workspace.recoveredOutput(item.id) == file)
    check(try workspace.publish(item) == file)
}

try checkBrowserInputCannotSetDestinationOrCredentials()
try checkHandoffAndPublishKeepExistingFileAndQuarantine()
print("Core checks passed.")
