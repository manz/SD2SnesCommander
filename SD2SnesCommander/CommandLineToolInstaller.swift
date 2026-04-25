import AppKit
import Foundation

// Symlinks the bundled sd2snes CLI into /usr/local/bin via an authorization
// prompt (osascript with administrator privileges). Mirrors the
// "Install Command Line Tools…" pattern used by Xcode and friends.
@MainActor
enum CommandLineToolInstaller {
    private static let installPath = "/usr/local/bin/sd2snes"

    static var bundledCLIPath: String {
        Bundle.main.bundlePath + "/Contents/Helpers/sd2snes"
    }

    static func install() {
        let source = bundledCLIPath
        guard FileManager.default.isExecutableFile(atPath: source) else {
            showAlert(
                style: .warning,
                title: "CLI Not Found",
                message: "Could not locate the sd2snes binary inside the app bundle at \(source)."
            )
            return
        }

        let escapedSource = source.replacingOccurrences(of: "\"", with: "\\\"")
        let shell = "mkdir -p /usr/local/bin && ln -sf \"\(escapedSource)\" \(installPath)"
        let appleScript = """
        do shell script "\(shell.replacingOccurrences(of: "\"", with: "\\\""))" with administrator privileges
        """

        var error: NSDictionary?
        NSAppleScript(source: appleScript)?.executeAndReturnError(&error)

        if let error {
            let message = error["NSAppleScriptErrorMessage"] as? String ?? "\(error)"
            showAlert(style: .warning, title: "Install Failed", message: message)
            return
        }

        showAlert(
            style: .informational,
            title: "Installed",
            message: "sd2snes is now available at \(installPath)."
        )
    }

    private static func showAlert(style: NSAlert.Style, title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// Force-restart the bundled USB XPC daemon when its state gets stuck — for
// example after a borked transfer leaves the C side holding a stale IOKit
// handle. SIGKILL because the XPC runtime swallows SIGTERM; launchd respawns
// the service on the next connection.
@MainActor
enum USBServiceController {
    private static let processName = "SD2SnesUSBService"

    static func restart() {
        let task = Process()
        task.launchPath = "/usr/bin/pkill"
        task.arguments = ["-9", "-x", processName]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Restart Failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
