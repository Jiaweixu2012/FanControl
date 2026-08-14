import SwiftUI

@main
struct FanControlApp: App {
    @StateObject private var env: AppEnvironment

    init() {
        let e = AppEnvironment()
        _env = StateObject(wrappedValue: e)
        e.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView(env: env)
        } label: {
            Image(systemName: "fanblades.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(env: env)
        }
    }
}
