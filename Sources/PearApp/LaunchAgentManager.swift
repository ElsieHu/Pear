import Foundation
import Darwin

/// Owns the per-user LaunchAgent that starts Pear at login.
///
/// The plist file is the single source of truth: `isEnabled` is simply whether
/// the file exists, so the settings switch can never lie about the real state.
/// `launchctl` registration is best-effort — from a non-GUI session it can
/// fail with `Bootstrap failed: 5`, but the file still takes effect at the
/// next login, which is why the UI says "变更将在下次登录生效".
///
/// Deliberately no `WatchPaths`: watching the whole external volume used to
/// re-run `open -a` on every file write, which could both activate the app
/// unexpectedly and resurrect an older copy of it. A login item should run
/// at login, and only then.
enum LaunchAgentManager {
    static let label = "local.pear"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The running app's own path, so a moved Pear.app is registered correctly
    /// the next time the switch is flipped.
    private static var appPath: String { Bundle.main.bundlePath }

    private static var plistText: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(appPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    static func setEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let text = plistText
            // Avoid rewriting an identical file (needless launchd churn).
            if (try? String(contentsOf: plistURL, encoding: .utf8)) != text {
                try? text.write(to: plistURL, atomically: true, encoding: .utf8)
            }
            register()
        } else {
            unregister()
            try? fm.removeItem(at: plistURL)
        }
    }

    private static func register() {
        runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private static func unregister() {
        runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
