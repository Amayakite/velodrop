# 发布流程

VeloDrop 使用 GitHub Actions 做两件事：

- `.github/workflows/ci.yml` 在 push 和 pull request 上构建并运行核心检查及浏览器回归测试，在 main 分支产出可下载的 DMG。
- `.github/workflows/release.yml` 在推送 `v*` tag 后重新打包、跑浏览器回归、验证镜像和签名、生成 SHA256，并创建 GitHub Release。

## 版本号约定

版本号的唯一来源是 [`Extension/manifest.json`](../Extension/manifest.json) 的 `version` 字段。`Scripts/package.sh` 会用它生成应用版本、DMG 文件名和浏览器扩展版本。

发布 tag 必须和 manifest 完全对应：

| manifest version | 合法 tag |
| --- | --- |
| `0.5.0` | `v0.5.0` |
| `0.6.0-beta.1` | `v0.6.0-beta.1` |

两者不一致时，release workflow 会在构建前直接失败，避免产出文件名和 Release 版本不一致的安装包。

## 正常发布

1. 修改 `Extension/manifest.json` 的版本号。
2. 在 [`CHANGELOG.md`](../CHANGELOG.md) 顶部新增对应版本小节。release workflow 会把该小节作为 GitHub Release 正文。
3. 本地验证：

   ```sh
   swift build -c release
   swift run -c release VeloCoreChecks
   plutil -lint Resources/zh-Hans.lproj/Localizable.strings
   for file in Extension/*.js; do node --check "$file"; done
   Scripts/package.sh .dist
   bash Scripts/browser-checks.sh .dist/VeloDrop.app
   hdiutil verify .dist/VeloDrop-*.dmg
   codesign --verify --deep --strict .dist/VeloDrop.app
   codesign --verify --deep --strict ".dist/Install VeloDrop.app"
   ```

4. 提交并推送 main：

   ```sh
   git add -A
   git commit -m "Release VeloDrop X.Y.Z"
   git push origin main
   ```

5. 创建并推送 tag：

   ```sh
   git tag -a vX.Y.Z -m "VeloDrop X.Y.Z"
   git push origin vX.Y.Z
   ```

6. 打开 GitHub 的 Actions → Release，确认 `Package and publish DMG` 成功；在 Releases 页面确认 DMG 和 `SHA256SUMS.txt` 已上传。

## 手动重跑

如果 Release 需要补传或重建：

1. 打开 Actions → Release → Run workflow。
2. 填写已存在的 tag，例如 `v0.5.0`。
3. workflow 会 checkout 该 tag，重新构建并覆盖上传 DMG 与校验文件；已存在的 Release 会被更新标题和说明，不会重复创建。

## 构建产物

- `.dist/VeloDrop-<version>-macos-arm64.dmg`
- `.dist/VeloDrop.app` 和 `.dist/Install VeloDrop.app`（本地构建产物，DMG 内只有安装器）
- `.dist/SHA256SUMS.txt`
- Actions artifact：`VeloDrop-<version>-build-<run_number>`（CI）或 `VeloDrop-<version>-release`（Release）

DMG 打开后显示「Install VeloDrop」。安装器会退出正在运行的旧版本、把应用原位替换到「应用程序」，然后重新打开。安装器的 Payload 位于 `Install VeloDrop.app/Contents/Resources/Payload/VeloDrop.app`。

GitHub 托管 runner 的 `macos-15` 标签当前是 arm64。工作流依赖 `uname -m` 生成架构后缀；如果未来 GitHub 调整 runner 标签，需要同步修改两个 workflow 的 `runs-on`，避免产出错误架构的安装包。

## 签名与公证

Firefox 的正式安装需要 Mozilla 签名。为 Release 工作流配置 `WEB_EXT_API_KEY` 和 `WEB_EXT_API_SECRET` 后，打包会通过 `web-ext sign --channel=unlisted` 生成 XPI，把它放入 DMG 及 Release。已有对应版本的签名文件时可设置 `VELODROP_FIREFOX_XPI` 直接打包。未配置凭据时，Firefox 仍可临时载入。见 [Mozilla 签名说明](https://extensionworkshop.com/documentation/publish/signing-and-distribution-overview/)。

当前发布流程和本地 `Scripts/package.sh` 默认使用 ad-hoc 签名（`VELODROP_SIGN_IDENTITY=-`），没有 Apple 公证。Release 说明会明确提示用户在 Finder 中右键打开。

如果之后配置 Developer ID：

- 本地可以设置 `VELODROP_SIGN_IDENTITY="Developer ID Application: ..."` 后运行 `Scripts/package.sh`。
- CI 需要在 workflow 中从 GitHub Secrets 导入 `.p12` 到临时 keychain，再设置同名环境变量，并补充 `notarytool` 公证与 `stapler` 装订步骤。当前仓库不保存任何证书或密码。

## 常见问题

- **Release 创建失败**：检查仓库 Settings → Actions → General → Workflow permissions 是否允许 GitHub Actions 写入内容；workflow 已声明 `permissions: contents: write`，但组织策略仍可能覆盖。
- **tag 和版本不一致**：修改 manifest 后重新打 tag；不要复用已推送的版本 tag。
- **DMG 构建失败**：先看 `build-engine.sh` 的 aria2 下载校验；缓存在 `.build/engine-*`，必要时在 Actions 页面清除 cache 后重跑。
- **首次打开被 macOS 拦截**：这是 ad-hoc 签名和未公证的预期行为，在 Finder 中右键「Install VeloDrop.app」选择「打开」。安装完成后打开的是已签名的 VeloDrop.app。
