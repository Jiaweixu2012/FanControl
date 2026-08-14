import SwiftUI
import AppKit
import FanControlCore

struct MenuBarPanelView: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var controller: FanController
    @State private var rpmText: String = ""

    init(env: AppEnvironment) {
        self.env = env
        self.controller = env.controller
        _rpmText = State(initialValue: controller.customRPM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = controller.errorMessage {
                Text(err).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !env.helperAvailable {
                installBanner
            }
            ForEach(controller.fans, id: \.index) { fan in
                FanRow(fan: fan)
            }
            if controller.fans.isEmpty {
                Text("未检测到风扇").font(.callout).foregroundColor(.secondary)
            }
            if let temp = controller.cpuTemp {
                Label(String(format: "CPU %.1f°C", temp), systemImage: "thermometer")
                    .font(.callout)
            }
            Divider()
            modePicker
            Divider()
            HStack {
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Label("打开设置", systemImage: "gearshape")
                    }
                } else {
                    Button("打开设置") { openSettings() }
                }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var installBanner: some View {
        HStack {
            Text("守护进程未安装").font(.caption)
            Spacer()
            Button("安装") { env.installHelper() }
        }
        .padding(6)
        .background(Color.yellow.opacity(0.2))
        .cornerRadius(6)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模式").font(.caption).foregroundColor(.secondary)
            Picker("", selection: $controller.mode) {
                ForEach(FanMode.allCases) { m in
                    Text(NSLocalizedString(m.localizedKey, comment: "")).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: controller.mode) { newMode in
                if newMode != .custom {
                    try? controller.applyMode()
                } else {
                    rpmText = controller.customRPM
                }
            }
            if controller.mode == .custom {
                HStack {
                    TextField("RPM", text: $rpmText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { applyCustom() }
                    Button("应用") { applyCustom() }
                        .disabled(!controller.isValidCustomRPM(rpmText, fans: controller.fans))
                }
            }
        }
    }

    private func applyCustom() {
        controller.customRPM = rpmText
        try? controller.applyMode()
    }

    private func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

struct FanRow: View {
    let fan: FanInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "风扇 %d", fan.index + 1))
                .font(.callout).fontWeight(.medium)
            Text("\(Int(fan.currentRPM)) RPM")
                .font(.title3).monospacedDigit()
            Text(String(format: "范围 %d - %d RPM", Int(fan.minRPM), Int(fan.maxRPM)))
                .font(.caption).foregroundColor(.secondary)
        }
    }
}
