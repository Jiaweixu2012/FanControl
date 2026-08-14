import SwiftUI
import FanControlCore

struct SettingsView: View {
    @ObservedObject var env: AppEnvironment
    @AppStorage("autoLaunch") private var autoLaunch = false

    var body: some View {
        Form {
            Toggle("开机自启动", isOn: $autoLaunch)
                .onChange(of: autoLaunch) { newValue in
                    AutoLaunch.setEnabled(newValue)
                }
            Section(header: Text("守护进程")) {
                HStack {
                    Text(env.helperAvailable ? "已安装并运行" : "未安装")
                    Spacer()
                    Button(env.helperAvailable ? "重新安装" : "安装") { env.installHelper() }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
