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
    try workspace.submit(item, reserve: true)
    check(workspace.incoming().isEmpty)
    try workspace.activate(item.id)
    try workspace.activate(item.id)
    check(workspace.incoming().map(\.1) == [item])
    let declined = try Transfer(url: URL(string: "https://example.com/other.pdf")!,
                                name: "other.pdf", fromBrowser: true)
    try workspace.submit(declined, reserve: true)
    try workspace.abandon(declined.id)
    checkThrows { try workspace.activate(declined.id) }
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
    check(workspace.recoveredOutput(item) == file)
    check(try workspace.publish(item) == file)
}

func checkBrowserHistoryAndRequestPrivacy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(root: root.appendingPathComponent("state"),
                              destination: root.appendingPathComponent("Downloads"))
    try workspace.prepare()
    let raw = URL(string: "https://example.com/report.zip?token=temporary#fragment")!
    var transfer = try Transfer(url: raw, name: "report.zip", fromBrowser: true)
    let headers = BrowserHeaders(["Cookie": "session=temporary", "Referer": "https://example.com/",
                                  "Host": "other.example", "Accept-Language": "en\nAnother: value"])
    check(headers.fields.count == 2)
    check(headers.requiresSession)
    check(transfer.sourceURL?.absoluteString == "https://example.com/report.zip")
    try workspace.submit(transfer, headers: headers)
    check(workspace.incoming().first?.2 == headers)
    transfer.url = nil
    transfer.state = .completed
    transfer.destinationPath = root.appendingPathComponent("Chosen").path
    try workspace.update(transfer)
    check(workspace.directory(for: transfer).lastPathComponent == "Chosen")
    let record = workspace.records.appendingPathComponent(transfer.id.uuidString + ".json")
    check(try !String(contentsOf: record, encoding: .utf8).contains("temporary"))
    try workspace.removeHistory(transfer)
    check(workspace.read(transfer.id) == nil)
    check(workspace.browserStatus(transfer.id)?.state == .completed)
    workspace.acknowledge(transfer.id)
    check(workspace.browserStatus(transfer.id) == nil)
}

func checkCollisionPoliciesAndBrowserOutcomes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(root: root.appendingPathComponent("state"), destination: root.appendingPathComponent("files"))
    try workspace.prepare()
    try FileManager.default.createDirectory(at: workspace.destination, withIntermediateDirectories: true)
    let target = workspace.destination.appendingPathComponent("report.pdf")
    try Data("original".utf8).write(to: target)
    var item = try Transfer(url: URL(string: "https://example.com/report.pdf")!, name: "report.pdf", fromBrowser: true)
    try FileManager.default.createDirectory(at: workspace.stage(item.id), withIntermediateDirectories: true)
    try Data("replacement".utf8).write(to: workspace.stage(item.id).appendingPathComponent("payload"))
    item.existingFilePolicy = .skip
    checkThrows { _ = try workspace.publish(item) }
    check(try Data(contentsOf: target) == Data("original".utf8))
    item.existingFilePolicy = .replace
    check(try workspace.publish(item) == target)
    check(try Data(contentsOf: target) == Data("replacement".utf8))
    check(workspace.ownsPublishedFile(target, id: item.id))
    check(workspace.recoveredOutput(item) == target)
    check(try workspace.publish(item) == target)
    item.state = .handedToBrowser
    try workspace.update(item)
    check(workspace.read(item.id)?.state == .handedToBrowser)
    check(workspace.browserStatus(item.id)?.state == .failed)
    try workspace.removeHistory(item)
    check(workspace.browserStatus(item.id)?.state == .failed)
    var canceled = try Transfer(url: URL(string: "https://example.com/cancel")!, name: "cancel", fromBrowser: true)
    canceled.state = .canceled
    try workspace.update(canceled)
    check(workspace.browserStatus(canceled.id)?.state == .canceled)
    // Optional additions must preserve records written before the redesign.
    let encoded = try JSONEncoder().encode(canceled)
    var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    for key in ["existingFilePolicy", "priority", "speedLimit"] { old.removeValue(forKey: key) }
    check(try JSONDecoder().decode(Transfer.self, from: JSONSerialization.data(withJSONObject: old)).id == canceled.id)
}

try checkCollisionPoliciesAndBrowserOutcomes()
try checkBrowserInputCannotSetDestinationOrCredentials()
try checkHandoffAndPublishKeepExistingFileAndQuarantine()
try checkBrowserHistoryAndRequestPrivacy()
print("Core checks passed.")
