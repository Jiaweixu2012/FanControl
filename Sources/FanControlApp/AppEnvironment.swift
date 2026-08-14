import SwiftUI
import Combine
import AppKit
import FanControlCore

/// Bridges FanController (core) to the app lifecycle: SMC reader,
/// helper client writer, persistence, timer, auto-launch.
final class AppEnvironment: ObservableObject {
    @Published var controller: FanController
    let helperInstaller: HelperInstaller
    @Published var helperAvailable: Bool

    private let defaults: UserDefaults
    private let smc = SMCConnection()
    private let helper = HelperClient()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.helperInstaller = HelperInstaller(bundlePath: Bundle.main.bundlePath)
        try? smc.open()
        helperAvailable = helperInstaller.helperResponding()

        let reader = SMCFanReader(smc: smc)
        let writer = helper
        controller = FanController(reader: reader, writer: writer)

        // restore saved state
        controller.mode = FanMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .auto
        if let saved = defaults.string(forKey: "customRPM") { controller.customRPM = saved }

        // persist changes
        controller.$mode.sink { [weak self] m in self?.defaults.set(m.rawValue, forKey: "mode") }.store(in: &cancellables)
        controller.$customRPM.sink { [weak self] rpm in self?.defaults.set(rpm, forKey: "customRPM") }.store(in: &cancellables)
    }

    func start() {
        controller.refresh()
        // re-apply saved mode after boot
        if controller.mode != .auto { try? controller.applyMode() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.controller.refresh()
        }
    }

    func installHelper() {
        // copy install.sh to a fixed /tmp location (no spaces) for a clean admin command
        let tmp = "/tmp/FanControlInstall.sh"
        try? FileManager.default.removeItem(atPath: tmp)
        do {
            try FileManager.default.copyItem(atPath: helperInstaller.bundledInstallScriptPath, toPath: tmp)
        } catch {
            controller.errorMessage = "无法复制安装脚本: \(error.localizedDescription)"
            return
        }
        let bundlePath = helperInstaller.appBundlePath
        let script = "do shell script \"/tmp/FanControlInstall.sh\" & space & quoted form of \"\(bundlePath)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.helperAvailable = self?.helperInstaller.helperResponding() ?? false
                if self?.helperAvailable == true { try? self?.controller.applyMode() }
            }
        }
        try? p.run()
    }

    private var settingsWindow: NSWindow?

    func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("settings.title", comment: "Settings")
        window.contentView = NSHostingView(rootView: SettingsView(env: self))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// FanReading backed by the real SMC connection
struct SMCFanReader: FanReading {
    let smc: SMCConnection
    func refreshFans() throws -> [FanInfo] {
        let count = smc.fanCount()
        var fans: [FanInfo] = []
        for i in 0..<count {
            if let s = smc.fanInfo(i) {
                fans.append(FanInfo(index: i, currentRPM: s.currentRPM, minRPM: s.minRPM, maxRPM: s.maxRPM))
            }
        }
        return fans
    }
    func cpuTemperature() throws -> Double? { smc.cpuTemperature() }
}
