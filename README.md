# VeloDrop

[![CI](https://github.com/Amayakite/velodrop/actions/workflows/ci.yml/badge.svg)](https://github.com/Amayakite/velodrop/actions/workflows/ci.yml)

VeloDrop 是一款原生 macOS 下载器。菜单栏图标打开下载窗口，也可通过 Dock 或 ⌘Tab 切回应用。Chrome、Edge、Brave、Vivaldi 和 Firefox 可以自动把普通文件下载交给 VeloDrop。

## 安装

1. 从 [GitHub Releases](https://github.com/Amayakite/velodrop/releases) 下载 DMG，双击打开，再双击「Install VeloDrop」。安装器会自动退出正在运行的旧版本、原位替换「应用程序」里的 VeloDrop 并重新打开，升级时不需要先手动退出旧版本。现成安装包适用于 Apple 芯片和 macOS 14 或更新版本。
2. 打开 VeloDrop，在「设置 → 浏览器」找到常用浏览器，点击「连接」，再点「复制路径并打开浏览器」。
3. Chrome、Edge、Brave 或 Vivaldi 中打开「开发者模式」，点击「加载解压缩的扩展」。在选择文件夹窗口按 **⇧⌘G**、粘贴路径并回车，再点击「选择文件夹」。若列表中已有 VeloDrop，使用扩展的「重新加载」。切换接管扩展时可以先暂停使用 FDM 等其他下载接管扩展。
4. Firefox 如随包附带签名，可点击「打开已签名的扩展」安装。临时载入时，在打开的 `about:debugging` 中点击「临时载入附加组件」，按 **⇧⌘G** 粘贴路径并选择 `manifest.json`。临时扩展需要在 Firefox 重启后重新载入。
5. 扩展载入后，可点击浏览器旁的「测试下载」。应用会接管一份本机测试文件并清理测试结果，设置里显示该浏览器是否通过。

GitHub 预发行包使用 ad-hoc 签名，尚未经过 Apple 公证。也可以在本机按下文从源码构建。打包脚本支持现有的 Developer ID 证书。

Mac 应用和浏览器扩展均支持简体中文和英文，分别跟随 macOS 和浏览器的界面语言。Firefox 使用独立的 Gecko manifest，但与 Chromium 版共享全部扩展代码。

[隐私政策 / Privacy Policy](docs/PRIVACY.md)

## 使用

- 从「应用程序」打开 VeloDrop 会显示下载窗口。关闭窗口后，仍可通过菜单栏的下载箭头或 Dock 打开窗口。浏览器自动接管时默认打开下载窗口，可在设置中关闭。
- 在浏览器里点下载，或在「添加下载」中粘贴 HTTP(S) 链接，每行一个，也可拖入链接。设置中可修改默认保存位置。同名文件可选择保留两份、跳过或替换。
- 默认接管已知大小至少 2 MiB 的普通文件。在 VeloDrop 设置的「浏览器」页可以调整接管开关、大小门槛，或让指定站点继续用浏览器。扩展只负责桥接，弹窗只显示连接状态和规则摘要，并可一键打开设置。站点规则同时检查下载地址、重定向后的地址和来源页。
- 设置里可选 1–16 路连接，默认 8 路，同时下载任务数可设为 1–10。可调整全局限速、单任务限速和任务优先级。续传取决于服务器是否支持字节范围和保留原文件。
- 下载过程中可以暂停、继续、取消，或把浏览器任务交还给浏览器。普通可重试的下载在浏览器确定文件名时接管，浏览器不弹出下载菜单，无需改浏览器设置。需要回退时，浏览器重新打开原下载链接。部分特殊链接会在交接时保留原任务，浏览器可能显示下载菜单。
- 默认开启「下载前弹窗确认」。窗口提供「用 VeloDrop 下载」「用浏览器下载」「取消下载」三个选择，可修改文件名、目录、连接数，或选择稍后下载。取消或关闭窗口会停止本次下载，后续请求依次确认。开始下载后自动打开进度窗口，显示百分比、速度、剩余时间、实际连接数和保存位置。下载中可调整连接数，调整时会短暂重连并续传。
- 下载窗口支持搜索、类型筛选、列排序、多选和批量删除。红色删除按钮显示选中数量和大小，询问删除文件和记录，或仅删除记录，可记住选择。文件移到 macOS 废纸篓，删除进行中任务会先停止下载。双击任务打开进度窗口，其中可继续查看时间、来源、保存位置、代理和已沿用的请求头名称。
- 默认沿用浏览器的 User-Agent 和可识别的代理配置。在 VeloDrop 设置中开启「沿用浏览器会话请求头」后，扩展会读取这次下载可用的会话头。固定 HTTP 代理和直连可交给 VeloDrop。PAC、SOCKS、识别出的非 GET 请求及无法可靠沿用的网络环境留给浏览器。
- 浏览器会话头只用于接管请求，重定向后的其他 URL 不接收这些头。详情保存头名称，来源链接去掉查询参数和片段。

### 终端命令

在「设置 → 通用 → 终端」点「安装终端命令」。勾选「同时安装短命令 vd」即可使用 `vd`。如果终端找不到命令，把 `export PATH="$HOME/.local/bin:$PATH"` 加入 shell 的启动文件（如 `~/.zshrc`），再打开新的终端。

```sh
velodrop 'https://example.com/file.zip'
vd --connections 12 --dir './packages' 'https://example.com/a.zip' 'https://example.com/b.zip'
velodrop --no-ui --wait 'https://example.com/file.zip'
```

命令会直接把链接提交给 VeloDrop，打开下载窗口并选中新任务。省略 `--connections` 或 `--dir` 会使用应用设置。`--dir` 的相对路径以终端当前目录为准。同名文件会保留两份。

`--no-ui` 在后台提交。`--wait` 等待整批下载结束，全部成功时退出码为 `0`，有任务失败、取消或提交失败时为 `1`，参数错误时为 `2`。命令向标准输出逐行写入任务 ID。按 Ctrl+C 可以结束终端等待，已提交的任务继续在应用中运行。

## 构建与验证

需要 macOS 14 或更新版本、Swift 6 和 Apple Command Line Tools。GitHub 目前提供 arm64 安装包。构建脚本为执行构建的 Mac 架构生成安装包。

```sh
Scripts/package.sh
swift run -c release VeloCoreChecks
node Scripts/cli-smoke.mjs
bash Scripts/browser-checks.sh
```

安装包位于 `.dist/`。设置 `VELODROP_SIGN_IDENTITY` 可用自己的 Developer ID 签名。端到端测试需要 Chrome、Edge、Firefox、geckodriver 和 Node.js 22 或更新版本。测试使用独立浏览器配置、临时连接器和本机 HTTP 测试服务。请在测试前退出同一套打包产物。

### 自动构建与发布

- push 和 pull request 会运行 Release 构建、核心检查、本地化和脚本校验、打包、终端命令及三款浏览器的回归测试。见 [CI](.github/workflows/ci.yml)。
- main 分支的 CI 会额外产出一个可用 Actions artifact 下载的未发布 DMG。
- 推送 `v*` tag 会触发 [Release](.github/workflows/release.yml)：在 arm64 `macos-15` runner 上重新打包、验证 DMG 与签名、生成 SHA256，并自动创建 GitHub Release。
- 版本号唯一来源是 `Extension/manifest.json`，发布 tag 必须与它一致。完整步骤、手动重跑、签名与常见问题见 [docs/RELEASING.md](docs/RELEASING.md)，版本记录见 [CHANGELOG.md](CHANGELOG.md)。

## 实现

- **Mac 界面**使用 SwiftUI 内容和 AppKit 标准窗口，所有窗口在屏幕可见区域居中显示；菜单栏通过 `NSStatusItem` 打开下载窗口。空闲时靠目录事件接收任务，下载引擎退出，扩展也停止周期检查。
- **下载**使用随包编译的 aria2 1.37.0，并行 HTTP(S) 分段和续传元数据由 aria2 维护。下载时仅通过有随机口令的本机回环接口与 aria2 通信。
- **安装与升级**由 DMG 内的轻量安装器完成：它退出正在运行的旧版本、原位替换应用并重新打开；应用内菜单和设置也可以检查更新，把 DMG 交给同一个安装器处理。规则和设置都保存在应用中，升级不会丢失。
- **浏览器交接**通过 MV3 扩展和一次性 Swift Native Messaging helper。扩展不保存接管设置，而是通过 helper 读取应用维护的 `browser-rules.json`。针对可重新请求的下载，连接器先登记任务，再在浏览器取消原任务后启动已登记的下载。文件写入临时目录，校验已知文件大小并添加 macOS 隔离属性后才保存到下载目录。
- **后续扩展**可在独立下载引擎层加入 BT 和磁力链接。

aria2 以独立程序随应用分发，安装包内含上游许可证、对应源码归档、限制浏览器请求头作用范围的补丁和构建脚本。界面和交接流程参考了原生菜单栏工具以及成熟下载器的做法，例如 [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)、[Haul](https://haul.sibiraj.dev/) 和 [Convoy](https://github.com/TheDynamicPunk/Convoy)。
