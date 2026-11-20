import AppKit
import Foundation

private enum L10n {
    static let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true

    static func text(_ english: String, _ chinese: String) -> String {
        self.chinese ? chinese : english
    }
}

private struct InstallerFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum Installer {
    static let identifier = "com.amayakite.velodrop"

    static func appVersion(at app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    static func defaultTarget() -> URL {
        let manager = FileManager.default
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        // Least surprise: replace the copy in Applications when it is writable,
        // otherwise install for this user only.
        if manager.isWritableFile(atPath: applications.path) {
            return applications.appendingPathComponent("VeloDrop.app")
        }
        return manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("VeloDrop.app")
    }

    static func quitRunningApp() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        guard !running.isEmpty else { return }
        for application in running {
            application.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && running.contains(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for application in running where !application.isTerminated {
            application.forceTerminate()
        }
        Thread.sleep(forTimeInterval: 0.4)
    }

    static func install(source: URL, target: URL) throws -> String {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: source.appendingPathComponent("Contents/MacOS/VeloDrop").path) else {
            throw InstallerFailure(message: L10n.text(
                "The VeloDrop app inside this installer is missing or damaged. Download the disk image again.",
                "安装程序中缺少 VeloDrop 应用，请重新下载安装包。"))
        }
        let directory = target.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw InstallerFailure(message: L10n.text(
                "VeloDrop could not write to Applications. Move the app there manually, then try again.",
                "VeloDrop 无法写入「应用程序」文件夹。请先手动把应用移入该文件夹，再重试。"))
        }

        // Prepare the new bundle before quitting the old one, so a failed copy
        // leaves the running app untouched.
        let staged = directory.appendingPathComponent(".VeloDrop.install-\(UUID().uuidString)")
        guard run("/usr/bin/ditto", [source.path, staged.path], failure: nil) else {
            try? manager.removeItem(at: staged)
            throw InstallerFailure(message: L10n.text(
                "The new version could not be copied to Applications.",
                "无法把新版本复制到「应用程序」文件夹。"))
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path], failure: nil)

        quitRunningApp()

        let backup = directory.appendingPathComponent(".VeloDrop.backup-\(UUID().uuidString)")
        var movedOld = false
        if manager.fileExists(atPath: target.path) {
            do {
                try manager.moveItem(at: target, to: backup)
                movedOld = true
            } catch {
                try? manager.removeItem(at: staged)
                throw InstallerFailure(message: L10n.text(
                    "The old copy could not be replaced: \(error.localizedDescription)",
                    "无法替换旧版本：\(error.localizedDescription)"))
            }
        }
        do {
            try manager.moveItem(at: staged, to: target)
        } catch {
            if movedOld { try? manager.moveItem(at: backup, to: target) }
            try? manager.removeItem(at: staged)
            throw InstallerFailure(message: L10n.text(
                "The new version could not be moved into Applications: \(error.localizedDescription)",
                "无法把新版本移入「应用程序」文件夹：\(error.localizedDescription)"))
        }
        if movedOld { try? manager.removeItem(at: backup) }
        return appVersion(at: target) ?? appVersion(at: source) ?? ""
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], failure: String?) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func detachVolumeInBackground() {
        let environment = ProcessInfo.processInfo.environment
        let mount: String
        if let override = environment["VELODROP_INSTALL_MOUNT"], override.hasPrefix("/") {
            mount = override
        } else {
            let path = Bundle.main.bundleURL.path
            guard path.hasPrefix("/Volumes/") else { return }
            let components = path.split(separator: "/")
            guard components.count >= 2 else { return }
            mount = "/" + components.prefix(2).joined(separator: "/")
        }
        var command = "sleep 3; /usr/bin/hdiutil detach '\(escaped(mount))' -quiet >/dev/null 2>&1 || true"
        command += "; /bin/rmdir '\(escaped(mount))' 2>/dev/null || true"
        if let artifact = environment["VELODROP_INSTALL_ARTIFACT"], artifact.hasPrefix("/") {
            command += "; /bin/rm -f '\(escaped(artifact))'"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

@MainActor
final class InstallerController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var titleLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var installButton: NSButton!
    private var cancelButton: NSButton!
    private var launchCheckbox: NSButton!
    private var installing = false
    private var cleanupStarted = false

    private let source: URL
    private let target: URL

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let bundle = Bundle.main
        let packaged = bundle.resourceURL?.appendingPathComponent("Payload/VeloDrop.app")
        let sibling = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("VeloDrop.app")
        if let packaged, FileManager.default.fileExists(atPath: packaged.path) {
            source = packaged
        } else {
            source = sibling
        }
        target = environment["VELODROP_INSTALL_TARGET"].map { URL(fileURLWithPath: $0) }
            ?? Installer.defaultTarget()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !FileManager.default.fileExists(atPath: source.path) {
            setStatus(L10n.text("The app inside this installer is missing.", "安装程序中缺少应用。"), error: true)
            installButton.isEnabled = false
        } else if ProcessInfo.processInfo.environment["VELODROP_INSTALL_AUTOSTART"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.install() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        scheduleCleanup()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !installing }

    private func scheduleCleanup() {
        guard !cleanupStarted else { return }
        cleanupStarted = true
        Installer.detachVolumeInBackground()
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 330),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("Install VeloDrop", "安装 VeloDrop")
        window.isReleasedWhenClosed = false
        window.delegate = self
        centerOnActiveScreen()

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        titleLabel = NSTextField(labelWithString: L10n.text("Install VeloDrop", "安装 VeloDrop"))
        titleLabel.font = .systemFont(ofSize: 21, weight: .bold)

        detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        updateVersionText()

        let header = NSStackView(views: [icon, makeTextStack([titleLabel, detailLabel])])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        statusLabel = NSTextField(labelWithString: L10n.text("Ready to install.", "准备安装。"))
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        launchCheckbox = NSButton(checkboxWithTitle: L10n.text("Open VeloDrop after installing",
                                                               "安装后打开 VeloDrop"),
                                  target: nil, action: nil)
        launchCheckbox.state = ProcessInfo.processInfo.environment["VELODROP_INSTALL_OPEN"] == "0" ? .off : .on
        launchCheckbox.font = .systemFont(ofSize: 11.5)

        let installTitle = Installer.isRunning()
            ? L10n.text("Quit VeloDrop and Install", "退出 VeloDrop 并安装")
            : L10n.text("Install", "安装")
        installButton = NSButton(title: installTitle, target: self, action: #selector(install))
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        installButton.controlSize = .large

        cancelButton = NSButton(title: L10n.text("Cancel", "取消"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.controlSize = .large

        let buttons = NSStackView(views: [launchCheckbox, NSView(), cancelButton, installButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [header, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -22),
        ])
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeTextStack(_ fields: [NSTextField]) -> NSStackView {
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2))
    }

    private func updateVersionText() {
        let installed = Installer.appVersion(at: target).map {
            L10n.text("Installed version \($0).", "已安装版本 \($0)。")
        } ?? L10n.text("VeloDrop is not installed yet.", "尚未安装 VeloDrop。")
        let incoming = Installer.appVersion(at: source).map {
            L10n.text("This installer contains VeloDrop \($0).", "此安装程序包含 VeloDrop \($0)。")
        } ?? ""
        let quit = Installer.isRunning()
            ? L10n.text("VeloDrop is running and will quit automatically before the app is replaced.",
                        "VeloDrop 正在运行，替换应用前会自动退出。")
            : L10n.text("The existing app will be replaced in place.",
                        "现有应用会在原位置被替换。")
        detailLabel.stringValue = installed + " " + incoming + " " + quit
    }

    private func setStatus(_ text: String, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func install() {
        guard !installing else { return }
        installing = true
        installButton.isEnabled = false
        cancelButton.isEnabled = false
        launchCheckbox.isEnabled = false
        window.standardWindowButton(.closeButton)?.isEnabled = false
        spinner.startAnimation(nil)
        setStatus(Installer.isRunning()
            ? L10n.text("Quitting the old version and installing…", "正在退出旧版本并安装…")
            : L10n.text("Installing…", "正在安装…"))

        let source = self.source
        let target = self.target
        let openAfter = launchCheckbox.state == .on
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let version = try Installer.install(source: source, target: target)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.spinner.stopAnimation(nil)
                    let suffix = version.isEmpty ? "" : " \(version)"
                    self.setStatus(L10n.text("VeloDrop\(suffix) installed.", "VeloDrop\(suffix) 已安装。"))
                    if openAfter {
                        self.openInstalledApp(at: target)
                    } else {
                        self.scheduleCleanup()
                        NSApp.terminate(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.installing = false
                    self.spinner.stopAnimation(nil)
                    self.installButton.isEnabled = true
                    self.cancelButton.isEnabled = true
                    self.launchCheckbox.isEnabled = true
                    self.window.standardWindowButton(.closeButton)?.isEnabled = true
                    self.setStatus(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func openInstalledApp(at app: URL) {
        setStatus(L10n.text("Opening VeloDrop…", "正在打开 VeloDrop…"))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.setStatus(error.localizedDescription, error: true)
                    self?.installButton.isEnabled = true
                    self?.cancelButton.isEnabled = true
                    self?.window.standardWindowButton(.closeButton)?.isEnabled = true
                    return
                }
                self?.scheduleCleanup()
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func cancel() {
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let controller = InstallerController()
    application.delegate = controller
    application.setActivationPolicy(.regular)
    application.run()
}
