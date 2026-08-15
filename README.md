# FanControl

macOS 菜单栏风扇转速管理工具（Intel Mac）。通过 SMC 读取/控制风扇转速，支持开机自启动、输入框自定义转速。

## ⚠️ 测试状态

> **仅在以下系统测试通过，其他机型/系统版本需自行验证：**
>
> - MacBook Pro 15,2 (Intel Core i5-8279U)
> - macOS 15.7
>
> 仅支持 **Intel Mac**。Apple Silicon (M 系列) 的 SMC 不允许手动控制风扇。

## 功能

- 菜单栏图标（点击弹出控制面板）
- 显示风扇实时转速 / 最小 / 最大、CPU 温度
- 控制模式：自动 / 最低 / 最高 / 自定义（输入框编辑 RPM）
- 多风扇支持（对全部风扇生效）
- 开机自启动
- 中英双语（跟随系统语言）

## 架构

SMC 写入需要 root 权限，因此分为两部分：

- **FanControl**（菜单栏 App，用户态）：读取 SMC、UI 控制
- **FanControlHelper**（root launchd 守护进程）：通过 Unix socket 接收命令并执行 SMC 写入

App 首次安装守护进程时需要输入一次管理员密码。

## 构建

```bash
./build.sh
# 产物: build/FanControl.app
```

要求：Swift 6+ (Xcode 16+)，macOS 13+

## 安装

```bash
cp -R build/FanControl.app /Applications/
```

打开 App → 点「安装」安装守护进程（需管理员密码）。

## 卸载守护进程

```bash
sudo launchctl bootout system/com.fancontrol.helper
sudo rm /Library/PrivilegedHelperTools/FanControlHelper /Library/LaunchDaemons/com.fancontrol.helper.plist
```

## 测试

```bash
swift test
```

## 项目结构

```
Sources/FanControlCore/    # 核心逻辑：SMC 访问、协议、控制逻辑（含单元测试）
Sources/FanControlApp/     # SwiftUI 菜单栏 App
Sources/FanControlHelper/  # root 守护进程
install.sh                 # 守护进程安装脚本
build.sh                   # 构建脚本
```
