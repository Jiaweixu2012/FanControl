import Foundation
import AppKit
import ServiceManagement

enum AutoLaunch {
    /// Register via SMAppService (macOS 13+); fall back to a LaunchAgent plist.
    static func setEnabled(_ on: Bool) {
        if on {
            do { try SMAppService.mainApp.register() }
            catch { installLaunchAgent() }
        } else {
            try? SMAppService.mainApp.unregister()
            removeLaunchAgent()
        }
    }

    private static var agentPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.fancontrol.app.plist")
    }

    private static func installLaunchAgent() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>com.fancontrol.app</string>
        <key>ProgramArguments</key>
        <array><string>\(Bundle.main.executablePath ?? "")</string></array>
        <key>RunAtLoad</key><true/>
        </dict></plist>
        """
        try? plist.write(to: agentPath, atomically: true, encoding: .utf8)
        _ = shell("launchctl unload \(agentPath.path) 2>/dev/null; launchctl load \(agentPath.path)")
    }

    private static func removeLaunchAgent() {
        _ = shell("launchctl unload \(agentPath.path) 2>/dev/null; rm -f \(agentPath.path)")
    }

    @discardableResult
    private static func shell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return ""
    }
}
