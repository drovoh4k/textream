//
//  UpdateChecker.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 9.02.2026.
//  Fork build: checks this repository's releases and installs them in place.
//

import AppKit

final class UpdateChecker: NSObject {
    static let shared = UpdateChecker()

    /// Releases are published by this fork's GitHub Actions workflow.
    private let repoOwner = "drovoh4k"
    private let repoName = "textream"

    private var isBusy = false
    private var progressPanel: UpdateProgressPanel?
    private var downloadSession: URLSession?
    private var pendingUpdate: PendingUpdate?

    private struct PendingUpdate {
        let version: String
        let appArchiveURL: URL?
        let diskImageURL: URL?
        let releaseURL: URL?
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Checking

    /// Check GitHub for the latest release and prompt the user if an update is available.
    func checkForUpdates(silent: Bool = false) {
        guard !isBusy else { return }

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }

            DispatchQueue.main.async {
                if let error {
                    if !silent {
                        self.showError("Could not check for updates.\n\(error.localizedDescription)")
                    }
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    if !silent {
                        self.showError("Could not parse the release information.")
                    }
                    return
                }

                let latestVersion = self.version(fromTag: tagName)
                guard self.isVersion(latestVersion, newerThan: self.currentVersion) else {
                    if !silent { self.showUpToDate() }
                    return
                }

                let assets = json["assets"] as? [[String: Any]] ?? []
                self.pendingUpdate = PendingUpdate(
                    version: latestVersion,
                    appArchiveURL: self.assetURL(in: assets, suffix: ".zip"),
                    diskImageURL: self.assetURL(in: assets, suffix: ".dmg"),
                    releaseURL: (json["html_url"] as? String).flatMap(URL.init(string:))
                )
                self.showUpdateAvailable(latestVersion: latestVersion)
            }
        }.resume()
    }

    private func assetURL(in assets: [[String: Any]], suffix: String) -> URL? {
        for asset in assets {
            guard let name = asset["name"] as? String,
                  name.lowercased().hasSuffix(suffix),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else { continue }
            return url
        }
        return nil
    }

    /// Tags are published as `drovo-1.7.0.42`, so take the first dotted number in the tag.
    private func version(fromTag tag: String) -> String {
        guard let range = tag.range(of: "[0-9]+(\\.[0-9]+)*", options: .regularExpression) else {
            return tag
        }
        return String(tag[range])
    }

    private func isVersion(_ remote: String, newerThan local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - Prompts

    private func showUpdateAvailable(latestVersion: String) {
        guard let update = pendingUpdate else { return }

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Textream \(latestVersion) is available. You are running \(currentVersion)."
        alert.alertStyle = .informational

        let canInstallInPlace = update.appArchiveURL != nil && isBundleWritable
        if canInstallInPlace {
            alert.addButton(withTitle: "Install and Relaunch")
        } else {
            alert.addButton(withTitle: "Download")
        }
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canInstallInPlace, let archive = update.appArchiveURL {
                startInstall(from: archive, version: latestVersion)
            } else if let fallback = update.diskImageURL ?? update.releaseURL {
                NSWorkspace.shared.open(fallback)
            }
        case .alertSecondButtonReturn:
            if let releaseURL = update.releaseURL {
                NSWorkspace.shared.open(releaseURL)
            }
        default:
            break
        }
    }

    /// In-place installation only makes sense when this build can rewrite its own bundle:
    /// a sandboxed build, or one installed in a folder the user cannot write to, cannot.
    private var isBundleWritable: Bool {
        // A sandboxed build cannot spawn ditto nor write outside its container.
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else { return false }
        let bundleURL = Bundle.main.bundleURL
        let parent = bundleURL.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
            && FileManager.default.isWritableFile(atPath: bundleURL.path)
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "Textream \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Install

    private func startInstall(from archiveURL: URL, version: String) {
        isBusy = true
        progressPanel = UpdateProgressPanel(title: "Updating to Textream \(version)…")
        progressPanel?.show()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: archiveURL).resume()
    }

    private func finishInstall(withDownloadedArchive archive: URL) {
        let bundleURL = Bundle.main.bundleURL

        do {
            // Same volume as the installed app: replaceItemAt can only swap within a volume,
            // and this is what makes the swap atomic instead of a copy.
            let workDirectory = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: bundleURL,
                create: true
            )
            defer { try? FileManager.default.removeItem(at: workDirectory) }

            let unpacked = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])

            guard let newBundle = try appBundle(in: unpacked) else {
                throw UpdateError.message("The downloaded archive does not contain Textream.app.")
            }

            let newIdentifier = Bundle(url: newBundle)?.bundleIdentifier
            guard newIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError.message("The downloaded app is not this application.")
            }

            // The archive comes straight from URLSession, so it carries no quarantine flag;
            // clear it anyway in case the file was handled by something else.
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newBundle.path])

            _ = try FileManager.default.replaceItemAt(bundleURL, withItemAt: newBundle)

            DispatchQueue.main.async {
                self.progressPanel?.close()
                self.progressPanel = nil
                self.isBusy = false
                self.relaunch(at: bundleURL)
            }
        } catch {
            let message: String
            if let updateError = error as? UpdateError, case .message(let text) = updateError {
                message = text
            } else {
                message = error.localizedDescription
            }

            DispatchQueue.main.async {
                self.progressPanel?.close()
                self.progressPanel = nil
                self.isBusy = false
                self.showInstallFallback(message: message)
            }
        }
    }

    private func showInstallFallback(message: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Install the Update"
        alert.informativeText = """
            \(message)

            If macOS refused the change, allow Textream under System Settings → Privacy & \
            Security → App Management, or install it by hand from the release page.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = pendingUpdate?.releaseURL ?? pendingUpdate?.diskImageURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reopen the freshly installed bundle once this process is gone, so the new instance is
    /// never fighting the old one over the same bundle identifier.
    private func relaunch(at bundleURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.2; done; "
            + "/usr/bin/open \"$1\""

        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The bundle path travels as an argument: a path with $, ` or " must not be parsed.
        relauncher.arguments = ["-c", script, "textream-relaunch", bundleURL.path]

        do {
            try relauncher.run()
        } catch {
            showError("Textream was updated but could not relaunch itself.\nOpen it again to finish.")
            return
        }

        NSApp.terminate(nil)
    }

    private func appBundle(in directory: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if let match = contents.first(where: { $0.pathExtension == "app" }) {
            return match
        }
        // Some archives wrap the app in a folder.
        for entry in contents where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let nested = try appBundle(in: entry) { return nested }
        }
        return nil
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError.message("\(launchPath) failed (\(process.terminationStatus)).\n\(output)")
        }
        return output
    }

    private enum UpdateError: Error {
        case message(String)
    }
}

// MARK: - Download progress

extension UpdateChecker: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.progressPanel?.update(fraction: fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        session.finishTasksAndInvalidate()

        // A 404 or 403 also lands here, with the error page as the "downloaded file".
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            DispatchQueue.main.async {
                self.progressPanel?.close()
                self.progressPanel = nil
                self.isBusy = false
                self.showInstallFallback(message: "The download failed (HTTP \(response.statusCode)).")
            }
            return
        }

        // The temporary file disappears when this method returns, so move it first.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextreamUpdate-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            DispatchQueue.main.async {
                self.progressPanel?.close()
                self.progressPanel = nil
                self.isBusy = false
                self.showInstallFallback(message: error.localizedDescription)
            }
            return
        }

        DispatchQueue.main.async {
            self.progressPanel?.setIndeterminate(message: "Installing…")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.finishInstall(withDownloadedArchive: staged)
            try? FileManager.default.removeItem(at: staged)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard let error else { return }
        DispatchQueue.main.async {
            self.progressPanel?.close()
            self.progressPanel = nil
            self.isBusy = false
            self.showInstallFallback(message: error.localizedDescription)
        }
    }
}

// MARK: - Progress window

private final class UpdateProgressPanel {
    private let window: NSWindow
    private let label: NSTextField
    private let progress: NSProgressIndicator

    init(title: String) {
        label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1

        let stack = NSStackView(views: [label, progress])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Textream"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = stack

        NSLayoutConstraint.activate([
            progress.widthAnchor.constraint(equalToConstant: 280)
        ])
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(fraction: Double) {
        progress.isIndeterminate = false
        progress.doubleValue = min(max(fraction, 0), 1)
    }

    func setIndeterminate(message: String) {
        label.stringValue = message
        progress.isIndeterminate = true
        progress.startAnimation(nil)
    }

    func close() {
        progress.stopAnimation(nil)
        window.orderOut(nil)
    }
}
