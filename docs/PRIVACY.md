# VeloDrop Privacy Policy

This policy applies to the VeloDrop browser extension and macOS companion app. The extension hands eligible downloads from your browser to the companion app on the same Mac. The developer does not receive your downloads, browsing activity, or session credentials. VeloDrop contains no advertising or telemetry.

## Information used for downloads

- The extension reads download details such as the URL, filename, file size, content type, and referring page. VeloDrop uses these details to apply your takeover rules and transfer eligible jobs to the local app. It also reads browser proxy settings to determine whether the same route can be used for the file.
- Reusing browser session headers is off by default. If you enable it, the extension holds a bounded set of recent HTTP(S) request details in browser memory. It uses matching request headers, which may include cookies and authorization tokens, to continue the selected download. Temporary handoff files are kept in a private folder on your Mac, and the companion app removes them after processing. Session header values are excluded from download history.
- The app requests the file from the source you chose, using the applicable proxy. Session headers received from the browser are scoped to the exact download URL. The app does not forward those headers to a different URL after a redirect.

## Storage and controls

VeloDrop saves download history and preferences locally. A download in progress can retain its full URL so the app can complete or resume it. The source shown in history omits query parameters and fragments. You can remove a download's record, or remove its record and move the downloaded file to the Trash.

In VeloDrop’s **Settings → Browsers**, you can turn off takeover or session header reuse and exclude sites. The extension does not run in private browsing.

When the app checks for updates, it requests version information and, if you install the update, the installer from GitHub Releases. The request contains no VeloDrop download history or session headers.

If you have a privacy question or need to report a security issue, see the [project contact options](https://github.com/Amayakite/velodrop).

---

# VeloDrop 隐私政策

本政策适用于 VeloDrop 浏览器扩展和 macOS 应用。扩展会把符合条件的下载任务交给同一台 Mac 上的应用。开发者不会收到你的下载内容、浏览活动或会话凭据。VeloDrop 无广告和遥测。

## 下载使用的信息

- 扩展会读取下载地址、文件名、文件大小、内容类型和来源页面等信息，据此应用接管规则，并将符合条件的任务交给本机应用。它也会读取浏览器的代理设置，以判断能否沿用该下载的网络路径。
- 「沿用浏览器会话请求头」默认关闭。打开后，扩展会在浏览器内存中暂存有限的近期 HTTP(S) 请求信息，仅将匹配本次下载的请求头用于继续该下载，其中可能包含 Cookie 和授权令牌。交接期间的临时文件保存在 Mac 的私有目录，应用处理后会清理。下载历史不会保存会话请求头的值。
- 应用向你选择的来源请求文件，并使用适用的代理。浏览器交给应用的会话请求头只用于对应的下载地址，发生重定向时不会被转发到另一个地址。

## 保存位置与控制

下载记录和偏好设置保存在本机。进行中的任务可暂存完整下载地址以便完成或续传，历史记录展示的来源地址会去掉查询参数和片段。你可以删除记录，也可以删除记录并将文件移到废纸篓。

在 VeloDrop 的「设置 → 浏览器」中，可以关闭自动接管或会话请求头复用，也可以指定不接管的网站。扩展不会在隐私浏览模式下运行。

应用检查更新时会从 GitHub Releases 获取版本信息。确认安装更新后，应用也会从那里下载安装包。更新请求不包含 VeloDrop 的下载历史或会话请求头。

如有隐私问题或需要报告安全问题，请查看[项目联系方式](https://github.com/Amayakite/velodrop)。
