import Foundation

public struct HelperInstaller {
    public let helperInstallPath: String
    public let daemonPlistPath: String
    public let socketPath: String
    public let bundledHelperPath: String
    public let bundledInstallScriptPath: String

    public init(bundlePath: String = Bundle.main.bundlePath) {
        helperInstallPath = "/Library/PrivilegedHelperTools/FanControlHelper"
        daemonPlistPath = "/Library/LaunchDaemons/com.fancontrol.helper.plist"
        socketPath = "/var/run/FanControlHelper.sock"
        bundledHelperPath = bundlePath + "/Contents/Resources/FanControlHelper"
        bundledInstallScriptPath = bundlePath + "/Contents/Resources/install.sh"
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: helperInstallPath)
    }

    public func helperResponding() -> Bool {
        HelperClient(socketPath: socketPath).ping()
    }

    /// App bundle path passed to install.sh (which is copied to /tmp before running as admin)
    public var appBundlePath: String {
        bundledInstallScriptPath.replacingOccurrences(of: "/Contents/Resources/install.sh", with: "")
    }
}
