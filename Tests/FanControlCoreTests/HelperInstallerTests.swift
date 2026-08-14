import XCTest
@testable import FanControlCore

final class HelperInstallerTests: XCTestCase {
    func testDefaultPaths() {
        let i = HelperInstaller(bundlePath: "/Applications/FanControl.app")
        XCTAssertEqual(i.helperInstallPath, "/Library/PrivilegedHelperTools/FanControlHelper")
        XCTAssertEqual(i.daemonPlistPath, "/Library/LaunchDaemons/com.fancontrol.helper.plist")
        XCTAssertEqual(i.socketPath, "/var/run/FanControlHelper.sock")
    }
    func testBundleSourcePaths() {
        let i = HelperInstaller(bundlePath: "/Applications/FanControl.app")
        XCTAssertEqual(i.bundledHelperPath, "/Applications/FanControl.app/Contents/Resources/FanControlHelper")
        XCTAssertEqual(i.bundledInstallScriptPath, "/Applications/FanControl.app/Contents/Resources/install.sh")
        XCTAssertEqual(i.appBundlePath, "/Applications/FanControl.app")
    }
}
