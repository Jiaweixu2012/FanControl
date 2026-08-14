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
- 目标机型已验证: MacBook Pro 15,2 (Intel i5-8279U, macOS 15.7)，2 个风扇。
- **读取 SMC 无需 root；写入 SMC 需要 root**（实测返回 kIOReturnNotPrivileged）→ 需要 root 守护进程（见"根守护进程"）。

## 技术栈

- 原生 Swift 6.2.4 + SwiftUI，macOS 13+ (MenuBarExtra)
- SPM (Swift Package Manager) 构建，`build.sh` 脚本组装 .app bundle
- SMC 访问: 直接调 IOKit `AppleSMC` 服务，不依赖第三方库
- 权限: root launchd 守护进程 (FanControlHelper) 执行 SMC 写入，菜单栏 App 通过 Unix socket 下发命令
- 图标: 用 CoreGraphics 程序化绘制，`iconutil` 打包成 .icns
- 开机自启: `SMAppService.mainApp`，回退 LaunchAgent
- 国际化: `Localizable.strings` + `.lproj`（en / zh-Hans），跟随系统语言（说明：String Catalog `.xcstrings` 无法被纯 SPM `swift build` 编译，故用传统 .strings 方案）

## 项目结构

```
FanControl/
├── Package.swift
├── Sources/
│   ├── FanControlCore/            # 核心逻辑（无 UI 依赖）
│   │   ├── SMCKit.swift           # IOKit/AppleSMC 读写封装（正确协议）
│   │   ├── FanController.swift    # 模式管理 + 定时刷新
│   │   └── Model.swift            # 模式枚举、风扇数据
│   ├── FanControlApp/             # SwiftUI 菜单栏 App（用户态）
│   │   ├── FanControlApp.swift    # @main + MenuBarExtra
│   │   ├── MenuBarPanelView.swift
│   │   ├── SettingsView.swift
│   │   ├── HelperClient.swift     # Unix socket 客户端
│   │   ├── HelperInstaller.swift  # 安装/卸载 root 守护进程
│   │   ├── Resources/Localizable.strings (en) + zh-Hans
│   │   └── Assets (图标 PNG)
│   └── FanControlHelper/          # root 守护进程（用户态 → root 写入）
│       ├── main.swift             # 启动参数 --daemon，监听 socket
│       └── SMCWrite.swift
├── install.sh                     # 安装脚本：复制 helper + LaunchDaemon plist
├── build.sh                       # swift build -c release → .app
├── Resources/make_icon.swift      # 程序化绘制风扇图标
└── docs/superpowers/specs/        # 本文档
```

## 组件设计

### 1. SMCKit (FanControlCore)

通过 IOKit 连接 `AppleSMC` 服务。**正确的调用协议（实测验证）**:

- 方法 selector 固定为 `KERNEL_INDEX_SMC = 2`；命令码写入结构体 `data8` 字段：
  - 5 = READ_BYTES，6 = WRITE_BYTES，9 = READ_KEYINFO
- 结构体为 devnull 版 80 字节布局（smcFanControl 的 116 字节 pLimitData 版是错误的）:
  - `key` 偏移 0，`keyInfo.dataSize` 偏移 28，`keyInfo.dataType` 偏移 32，`data8` 偏移 42，`bytes` 偏移 48
- 键名: native-endian 存储的 UInt32 fourcc（`'F'<<24|'N'<<16|'u'<<8|'m'`，直接写入内存，**不做字节交换**）
- READBYTES 前必须把 `keyInfo.dataSize`（和 dataType）从 KEYINFO 结果回填到输入结构
- 数据格式**按型号自适应**：读 KEYINFO 的 dataType，`flt `（4字节 Float）与 `fpe2`（2字节）都支持；实测本机风扇键是 `flt `

- 读取（用户态 App 直接做）:
  - `FNum` (ui8) — 风扇数量
  - `F0Ac`..`FnAc` (flt/fpe2) — 当前风扇转速 (RPM)
  - `F0Mn`..`FnMn` (flt/fpe2) — 风扇最低转速
  - `F0Mx`..`FnMx` (flt/fpe2) — 风扇最高转速
  - `TC0P` (sp78) — CPU 温度 (°C)，按 sp78 解码：`Int(b[0])<<8 | Int(b[1])` 再 /256（固定使用 TC0P，不使用 TC0E）
- 写入（仅由 root 守护进程执行）:
  - `F0Md`..`FnMd` (ui8) — 手动模式开关 (1=手动, 0=自动)，写 1 字节，keyInfo.dataSize=1
  - `F0Tg`..`FnTg` (flt/fpe2) — 目标转速 (RPM)，写 4 字节 (flt)，keyInfo.dataSize=4
  - 注意：写入也必须把 keyInfo.dataSize（和 dataType）回填到输入结构，否则写入失败

API:
```swift
struct FanInfo { index, currentRPM, minRPM, maxRPM }
enum SMCError: Error { case connectionFailed, readFailed, writeFailed, notPrivileged }

class SMCKit {
    func fanCount() -> Int
    func fanInfo(_ index: Int) -> FanInfo
    func cpuTemp() -> Double
    // 以下仅 root 进程调用：
    func setManualMode(_ index: Int, enabled: Bool) throws
    func setTargetSpeed(_ index: Int, rpm: Double) throws
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
    @Published var helperInstalled: Bool

    func applyMode()          // 按当前模式通过 helper 写入 SMC；Picker 切换即时生效，自定义模式需点击"应用"
    func refresh()            // 定时读取 (每 2 秒)
    func startTimer() / stopTimer()
}
```

行为:
- `auto`: 写 `F0Md`=0（恢复系统控制）
- `min`: 写 `F0Md`=1 + `F0Tg`=`F0Mn`
- `max`: 写 `F0Md`=1 + `F0Tg`=`F0Mx`
- `custom`: 写 `F0Md`=1 + `F0Tg`=输入框解析出的 RPM（校验范围 min..max，非法输入提示）

**作用域（多风扇）**: 模式与自定义 RPM 对**所有**检测到的风扇生效（目标机为双风扇）。自定义 RPM 的输入校验范围取全局范围：所有风扇 min 的最小值 .. 所有风扇 max 的最大值；实际应用时对每个风扇按其自身 [F0Mn, F0Mx] 做 clamp，防止越界。

**启动行为（含开机自启）**: App 启动时从 `@AppStorage` 恢复上次保存的模式和自定义 RPM，并**立即通过 helper 重新写回 SMC**（与 smcFanControl 一致：用户设置的手动转速在重启后保持）。启动时同时开始 2 秒定时轮询刷新显示。若 helper 未安装，提示安装。

### 3. Root 守护进程 (FanControlHelper)

- 与 App 同一二进制? 否——独立可执行文件，root 运行。
- 安装位置: `/Library/PrivilegedHelperTools/FanControlHelper`，LaunchDaemon plist 位于 `/Library/LaunchDaemons/com.fancontrol.helper.plist`（ProgramArguments = [helperPath, "--daemon"], RunAtLoad）。
- 启动时创建 Unix socket `/var/run/FanControlHelper.sock`（**chmod 0666**，否则 root 创建、用户态 App 无法 connect），监听命令（行协议，JSON）:
  - `{"cmd":"ping"}`
  - `{"cmd":"set","index":0,"rpm":2000.0}` — 写入 F0Md=1 + F0Tg（mode 字段可省略/忽略，daemon 只做 F0Md=1）
  - `{"cmd":"auto","index":0}` — 写入 F0Md=0
  - `{"cmd":"shutdown"}` — 退出（仅卸载流程调用）
- 每个命令返回 JSON: `{"ok":true}` 或 `{"ok":false,"error":"..."}`。
- 无命令时保持空转，连接数低占用。
- App 通过 HelperClient 连接 socket 下发命令并读回结果。**applyMode 对每个检测到的风扇各发一条命令**（daemon 无"全部风扇"命令）。

### 4. SwiftUI 界面 (FanControlApp)

- `MenuBarExtra` 菜单栏图标: 程序化生成的单色风扇 template 图像
- 面板内容:
  - 每个风扇: 当前转速、最小/最大
  - CPU 温度
  - 模式 Picker (自动/最低/最高/自定义)
  - 自定义模式: TextField(RPM) + "应用" 按钮，实时校验
  - 开机自启 Toggle
  - helper 状态（未安装时显示"安装守护进程"按钮，一次性输管理员密码）
  - "打开设置"、"退出" 按钮
- 持久化: `@AppStorage` 保存模式、自定义 RPM、自启开关、helper 已安装标记

### 5. 安装/卸载守护进程 (HelperInstaller + install.sh)

- App 首次需要调速时: 检查 socket 是否可连 → 不可连则把 bundle 内 `Resources/install.sh` 复制到临时目录，用 `osascript` 以管理员权限运行 `install.sh`（复制 helper 到 /Library/PrivilegedHelperTools、写 plist、`launchctl bootstrap` 加载、启动后自检 SMC 写入）。`install.sh` 与 helper 一起打进 App bundle（Resources/）。
- 设置窗口提供"卸载守护进程"（同样提权执行卸载脚本）。
- 验证: 安装后 helper 自检 SMC 写入（试写 F0Md 同值并还原），返回结果给 App 显示。

### 6. 开机自启动（App 自身）

- 主路径: `SMAppService.mainApp.register()`，需 App 位于 /Applications。
- 回退: 写入 `~/Library/LaunchAgents/com.fancontrol.app.plist` (RunAtLoad)。
- 状态读取: `SMAppService.mainApp.status` 或检查 plist 是否存在。

### 7. build.sh

1. `swift build -c release --product FanControl`（SPM 产品名 = `FanControl`，可执行 target = `FanControlApp`，二进制产物直接用于 .app）
2. `swift build -c release --product FanControlHelper`（root 守护进程二进制）
3. `swift Resources/make_icon.swift` 生成 PNGs → `iconutil -c icns`
4. 组装 `FanControl.app/Contents`:
   - `MacOS/FanControl` (可执行文件)
   - `Info.plist` (CFBundleIdentifier: com.fancontrol.app, LSUIElement=YES)
   - `Resources/AppIcon.icns`
   - `Resources/zh-Hans.lproj` + `en.lproj` 字符串
5. `codesign --force --sign -` 临时签名（本地运行用）
6. 将 `FanControlHelper` 放到 `FanControl.app/Contents/Resources/FanControlHelper`（安装时由 install.sh 复制到 /Library）

### 8. 图标生成 (make_icon.swift)

用 CoreGraphics 绘制: 圆形深色底 + 白色风扇叶图案，输出多尺寸 PNG
(16, 32, 64, 128, 256, 512, 1024)，再转 .icns。
菜单栏 template 图标单独绘制（纯单色）。

## 错误处理

- SMC 读取失败: 面板显示错误横幅，App 不崩溃
- helper 未安装 / socket 连不上: 提示安装守护进程（按钮触发提权安装）
- 写入失败（helper 返回错误）: 面板显示错误并保持 UI 一致
- 非法 RPM 输入: 字段标红，按钮禁用，提示有效范围
- 自启注册失败: 显示错误信息并提示手动方案

## 测试

- SPM 测试目标: SMCKit 键计算、flt/fpe2 编解码、范围校验、模式应用逻辑（mock SMC 层）、socket 协议编解码的纯逻辑单测
- 手动验收（需 root）: 在目标 MacBook Pro 上验证 helper 安装、各模式切换、输入框生效、开机自启、图标显示

## 非目标 (YAGNI)

- 温度曲线/阈值自动调速（用户选择了简单多模式）
- Apple Silicon 支持（硬件不支持手动风扇控制）
- 风扇转速图表/历史记录
- 自动更新
