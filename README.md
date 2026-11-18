# VeloDrop

VeloDrop 是一款原生 macOS 下载器。菜单栏显示下载速度，点开就能查看和管理队列。Microsoft Edge 可以自动把普通文件下载交给 VeloDrop。

## 安装

1. 从 [GitHub Releases](https://github.com/Amayakite/velodrop/releases) 下载 ZIP，解压后把 `VeloDrop.app` 放进「应用程序」并打开。现成安装包适用于 Apple 芯片和 macOS 14 或更新版本。
2. 点击菜单栏的下载箭头，打开「设置」，再点击「配置 Edge」。VeloDrop 会为当前用户注册连接器，打开 Edge 的扩展页，并在访达中显示扩展文件夹。
3. 在 Edge 打开「开发人员模式」，点击「加载解压缩的扩展」，选择访达里高亮的 `EdgeExtension` 文件夹。点击 Edge 工具栏上的小图标，确认显示已连接。初次切换时，可以先停用 FDM 等其他下载接管扩展。

GitHub 预发行包使用 ad-hoc 签名，尚未经过 Apple 公证。也可以在本机按下文从源码构建。打包脚本支持现有的 Developer ID 证书。

## 使用

- 在 Edge 里点下载，或在 VeloDrop 的菜单栏面板粘贴 HTTP(S) 链接。保存位置是当前用户的「下载」文件夹，遇到同名文件会添加数字后缀。
- 扩展默认接管已知大小至少 2 MiB 的普通文件。在扩展弹窗可以调整大小门槛、暂停自动接管，或让指定站点继续用 Edge。
- 设置里可选 1、4、8 或 16 路连接，默认 8 路。支持分段的服务器会进行并行下载，续传取决于服务器是否支持字节范围和保留原文件。
- 下载过程中可以暂停、继续、取消，或把浏览器任务交还给 Edge。VeloDrop 保存成功后才取消 Edge 中保留的任务；如果服务器拒绝下载或连接器失败，Edge 可以继续原任务。
- 扩展使用浏览器的下载权限和 Native Messaging，不读取登录 Cookie。必须携带浏览器登录状态的文件会在接管失败后交还给 Edge。接管期间如果手动移除扩展，可以在 Edge 下载列表中继续保留的任务。

## 构建与验证

需要 macOS 14 或更新版本、Swift 6 和 Apple Command Line Tools。GitHub 目前提供 arm64 安装包。构建脚本为执行构建的 Mac 架构生成安装包。

```sh
Scripts/package.sh
swift run -c release VeloCoreChecks
node Scripts/smoke-test.mjs
```

安装包位于 `.dist/`。设置 `VELODROP_SIGN_IDENTITY` 可用自己的 Developer ID 签名。端到端测试需要安装 Microsoft Edge 和 Node.js 22 或更新版本，使用临时浏览器配置、临时下载目录和本机 HTTP 测试服务。请在测试前退出同一套打包产物。

## 实现

- **Mac 界面**使用 SwiftUI `MenuBarExtra`。空闲时靠目录事件接收任务，下载引擎退出，扩展也停止周期检查。
- **下载**使用随包编译的 aria2 1.37.0，并行 HTTP(S) 分段和续传元数据由 aria2 维护。下载时仅通过有随机口令的本机回环接口与 aria2 通信。
- **浏览器交接**通过 MV3 扩展和一次性 Swift Native Messaging helper。Edge 在交接期间保留原任务。文件写入临时目录，校验已知文件大小并添加 macOS 隔离属性后才保存到下载目录。
- **后续扩展**可在独立下载引擎层加入 BT 和磁力链接。

aria2 以独立程序随应用分发，安装包内含上游许可证、对应源码归档和构建脚本。界面和交接流程参考了原生菜单栏工具以及成熟下载器的做法，例如 [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)、[Haul](https://haul.sibiraj.dev/) 和 [Convoy](https://github.com/TheDynamicPunk/Convoy)。
