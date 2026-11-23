# VeloDrop Chromium store submission

## Package and connector

1. From the repository root, run `bash Scripts/package-chromium.sh` on macOS. The output is `.dist/VeloDrop-<version>-Chromium.zip`. Both Chromium stores use this ZIP. It contains the extension at the archive root and leaves the storefront signing key to each store.
2. Upload the ZIP as a draft in the [Chrome Web Store Developer Dashboard](https://chrome.google.com/webstore/devconsole/) and [Microsoft Partner Center](https://partner.microsoft.com/dashboard/microsoftedge/overview).
3. Record the store-assigned extension ID for each draft. Before submitting, add the verified IDs to the Mac companion's native messaging allowlist in `Sources/VeloDrop/BrowserSupport.swift`. Keep the current unpacked extension ID for existing users. Chrome Web Store installs in Chromium derivatives should use the Chrome Web Store ID. Edge can install from either store.
4. Release a companion DMG with that allowlist. Test the assigned extension identity and its handoff using **VeloDrop → Settings → Browsers → Test Download** before submitting. The store listing can point to [the latest DMG](https://github.com/Amayakite/velodrop/releases/latest) once it supports the store extensions.

The browser extensions require an Apple silicon Mac with macOS 14 or later and the VeloDrop companion. Describe this requirement in both listings and reviewer notes. [Chrome extension IDs](https://developer.chrome.com/docs/extensions/reference/manifest/key) · [Edge native messaging](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/native-messaging)

## Listing copy

**English description**

VeloDrop sends eligible file downloads to the VeloDrop download manager on your Mac. Pick a destination when a download starts, check progress and connection count, or send the download back to the browser. The app lets you set a minimum size and keep selected sites in the browser.

Requires the free VeloDrop companion app on an Apple silicon Mac with macOS 14 or later. After installing the app and this extension, open **VeloDrop → Settings → Browsers** to connect the browser and run a test download.

**简体中文描述**

VeloDrop 将符合条件的文件下载交给 Mac 上的 VeloDrop 下载器。你可以在开始时选择保存位置，查看下载进度和连接数，或把任务交回浏览器。应用内可设置最小接管大小，以及始终由浏览器处理的网站。

下载记录集中保存在 Mac 上。完成后可直接打开文件、在访达中显示，或者批量删除记录和文件。下载失败时，符合条件的浏览器任务会交回原浏览器。需要登录才能下载的文件，可以按需启用会话请求头复用，让应用沿用匹配本次下载的会话信息。

需要安装 VeloDrop Mac 应用，适用于 Apple 芯片和 macOS 14 或更新版本。完成安装后，打开「VeloDrop → 设置 → 浏览器」，连接当前浏览器并测试下载。

VeloDrop 在本机处理下载信息，开发者不会收到你的下载记录或会话凭据。你可以随时暂停自动接管，并继续使用浏览器原有的下载方式。

**Website** [VeloDrop](https://github.com/Amayakite/velodrop)

**Privacy policy** [VeloDrop privacy policy](https://github.com/Amayakite/velodrop/blob/main/docs/PRIVACY.md)

## Privacy and permission fields

**Single purpose** Send eligible HTTP(S) file downloads from the browser to the VeloDrop app on the same Mac.

| Permission | Justification |
| --- | --- |
| `downloads` | Observe new file downloads and let the browser continue when the companion declines a handoff. |
| `nativeMessaging` | Send a selected download to the user's separately installed local VeloDrop helper. |
| `storage` | Track incomplete handoffs and the companion version locally so the worker can recover a handoff after a restart. |
| `alarms` | Check outstanding handoffs and stop checking when no jobs are left. |
| `webRequest` and HTTP(S) host access | Match recent request details to a download when the user enables browser session header reuse in VeloDrop. Downloads can come from any HTTP(S) host. |
| `proxy` | Read the browser proxy mode to use the correct download route or leave the task in the browser. |

The extension uses packaged code. It handles download URLs and referring pages locally. It uses cookies and authorization headers for matching downloads when the user enables that setting. Disclose that use of authentication information and browsing information even though the developer does not receive it. [Chrome user data disclosures](https://developer.chrome.com/docs/webstore/program-policies/user-data-faq) · [Edge submission instructions](https://learn.microsoft.com/en-us/microsoft-edge/extensions/publish/publish-extension)

## Review notes

1. Install the companion DMG that supports the submitted store ID on an Apple silicon Mac with macOS 14 or later.
2. Install the submitted extension and connect the browser in **VeloDrop → Settings → Browsers**.
3. Click **Test Download** for the browser. It uses a temporary local fixture and reports success in the browser row. No test credentials are required.
4. For the normal confirmation flow, use a downloadable ZIP or DMG larger than 2 MiB. The confirmation window allows a native download, a return to the browser, or cancellation.
