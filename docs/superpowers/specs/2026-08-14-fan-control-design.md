# FanControl — macOS 风扇转速管理工具设计文档

日期: 2026-08-14

## 目标

构建一个 macOS 菜单栏小工具，用于手动控制 Intel Mac 的风扇转速。功能包括：

- 菜单栏小图标（仅图标，template，深色模式自适应）
- 启动器图标（App 图标，程序化生成）
- 开机自启动
- 输入框编辑转速（自定义 RPM）

## 硬件前提

- **仅支持 Intel Mac**。Apple Silicon (M 系列) 的 SMC 不允许手动控制风扇。
- 目标机型已验证: MacBook Pro (Intel i5-8279U, macOS 15.7)。
- 通过 SMC 键读写风扇，无需 root（与 smcFanControl 一致）。

## 技术栈

- 原生 Swift 6.2.4 + SwiftUI，macOS 13+ (MenuBarExtra)
- SPM (Swift Package Manager) 构建，`build.sh` 脚本组装 .app bundle
- SMC 访问: 直接调 IOKit `AppleSMC` 服务，不依赖第三方库
- 图标: 用 CoreGraphics 程序化绘制，`iconutil` 打包成 .icns
- 开机自启: `SMAppService.mainApp`，回退 LaunchAgent
- 国际化: String Catalog，跟随系统语言 (中/英)

## 项目结构

```
FanControl/
├── Package.swift
├── Sources/
│   ├── FanControlCore/            # 核心逻辑（无 UI 依赖）
│   │   ├── SMCKit.swift           # IOKit/AppleSMC 读写封装
│   │   ├── FanController.swift    # 模式管理 + 定时刷新
│   │   └── Model.swift            # 模式枚举、风扇数据
│   └── FanControlApp/             # SwiftUI 菜单栏 App
│       ├── FanControlApp.swift    # @main + MenuBarExtra
│       ├── MenuBarPanelView.swift
│       ├── SettingsView.swift
│       ├── Resources/Localizable.strings (en) + zh-Hans
│       └── Assets (图标 PNG)
├── build.sh                       # swift build -c release → .app
├── Resources/make_icon.swift      # 程序化绘制风扇图标
└── docs/superpowers/specs/        # 本文档
```

## 组件设计

### 1. SMCKit (FanControlCore)

基于 smcFanControl 已知的 SMC 键定义，通过 IOKit 连接 `AppleSMC` 服务:

- `read(key, type)` -> Data / 数值
- 读取:
  - `FNum` (ch8) — 风扇数量
  - `F0Ac`..`FnAc` (fpe2) — 当前风扇转速 (RPM)
  - `F0Mn`..`FnMn` (fpe2) — 风扇最低转速
  - `F0Mx`..`FnMx` (fpe2) — 风扇最高转速
  - `TC0P`/`TC0E` (sp78) — CPU 温度 (°C)
- 写入:
  - `F0Md`..`FnMd` (ch8) — 手动模式开关 (1=手动, 0=自动)
  - `F0Tg`..`FnTg` (fpe2) — 目标转速 (RPM)

API:
```swift
struct FanInfo { index, currentRPM, minRPM, maxRPM }
enum SMCError: Error { case connectionFailed, readFailed, writeFailed }

class SMCKit {
    func fanCount() -> Int
    func fanInfo(_ index: Int) -> FanInfo
    func setManualMode(_ index: Int, enabled: Bool)
    func setTargetSpeed(_ index: Int, rpm: UInt16)
    func cpuTemp() -> Double
}
```

### 2. FanController (FanControlCore)

业务逻辑层，持有 App 状态:

```swift
enum FanMode: String, Codable { case auto, min, max, custom }

class FanController: ObservableObject {
    @Published var mode: FanMode
    @Published var customRPM: String   // 输入框文本
    @Published var fans: [FanInfo]
    @Published var cpuTemp: Double
    @Published var errorMessage: String?

    func applyMode()          // 按当前模式写入 SMC
    func refresh()            // 定时读取 (每 2 秒)
    func startTimer() / stopTimer()
}
```

行为:
- `auto`: 写 `F0Md`=0（恢复系统控制）
- `min`: 写 `F0Md`=1 + `F0Tg`=`F0Mn`
- `max`: 写 `F0Md`=1 + `F0Tg`=`F0Mx`
- `custom`: 写 `F0Md`=1 + `F0Tg`=输入框解析出的 RPM（校验范围 min..max，非法输入提示）

### 3. SwiftUI 界面 (FanControlApp)

- `MenuBarExtra` 菜单栏图标: 程序化生成的单色风扇 template 图像
- 面板内容:
  - 每个风扇: 当前转速、最小/最大
  - CPU 温度
  - 模式 Picker (自动/最低/最高/自定义)
  - 自定义模式: TextField(RPM) + "应用" 按钮，实时校验
  - 开机自启 Toggle
  - "打开设置"、"退出" 按钮
- 设置窗口 (可选，可用 @AppStorage 存储)
- 持久化: `@AppStorage` 保存模式、自定义 RPM、自启开关

### 4. 开机自启动

- 主路径: `SMAppService.mainApp.register()`，需 App 位于 /Applications。
- 回退: 写入 `~/Library/LaunchAgents/com.fancontrol.app.plist` (RunAtLoad)。
- 状态读取: `SMAppService.mainApp.status` 或检查 plist 是否存在。

### 5. build.sh

1. `swift build -c release --product FanControl`
2. `swift Resources/make_icon.swift` 生成 PNGs → `iconutil -c icns`
3. 组装 `FanControl.app/Contents`:
   - `MacOS/FanControl` (可执行文件)
   - `Info.plist` (CFBundleIdentifier: com.fancontrol.app, LSUIElement=YES)
   - `Resources/AppIcon.icns`
   - `Resources/zh-Hans.lproj` + `en.lproj` 字符串
4. `codesign --force --sign -` 临时签名（本地运行用）

### 6. 图标生成 (make_icon.swift)

用 CoreGraphics 绘制: 圆形深色底 + 白色风扇叶图案，输出多尺寸 PNG
(16, 32, 64, 128, 256, 512, 1024)，再转 .icns。
菜单栏 template 图标单独绘制（纯单色）。

## 错误处理

- SMC 连接失败 / 读写失败: 面板顶部显示错误横幅，App 不崩溃
- 非法 RPM 输入: 字段标红，按钮禁用，提示有效范围
- 自启注册失败: 显示错误信息并提示手动方案

## 测试

- `make test`（SPM 测试目标）: SMCKit 键计算、RPM 解析、范围校验的纯逻辑单测
- 手动验收: 在目标 MacBook Pro 上验证各模式切换、输入框生效、自启、图标显示

## 非目标 (YAGNI)

- 温度曲线/阈值自动调速（用户选择了简单多模式）
- Apple Silicon 支持（硬件不支持手动风扇控制）
- 风扇转速图表/历史记录
- 自动更新
