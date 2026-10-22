# 自用 fork

本仓库是 [`y0un922/baocode`](https://github.com/y0un922/baocode)，上游为 [`baocode-dev/baocode`](https://github.com/baocode-dev/baocode)。

## 名称与图标

本 fork 的应用名为 **Baogong**，中文系统下显示为**包工头**；图标是戴安全帽的像素包子（`tool/fork_icon.py` 生成全部尺寸、`assets/branding/logo.svg` 与菜单栏图标的格子）。

- 应用文件夹为 `Baogong.app`，包标识为 `io.github.y0un922.baogong`（Finder 扩展为其 `.FinderExtension`），可与官方 BaoCode 同时安装。
- 显示名：`macos/Runner/Info.plist` 的 `CFBundleName`/`CFBundleDisplayName`，中文名在 `macos/packaging/zh-Hans.lproj/InfoPlist.strings`，由 `tool/build_macos.dart` 在签名前放入应用；包内可执行文件仍叫 `BaoCode`。
- 界面文字中指本应用的 “BaoCode” 已改为包工头 / Baogong；指上游的保留原名：Chrome 商店的浏览器扩展（及其“BaoCode”标签页分组和工具栏按钮）、手机 App 与中转、官网更新与诊断、推荐站点列表、GitHub 授权应用。
- 不改内部名称，以便继续合入上游：数据目录 `~/Library/Application Support/baocode`、`BAOCODE_*` 环境变量、`baocode-agent`、浏览器扩展的原生连接名、`baocode://` 链接、钥匙串服务名、`~/BaoCode/Stash`。因此与官方版共用同一份数据，两者不要同时打开。

## 更新方式

本 fork **默认不启用安装包更新**，包括 release 构建。官方安装包会替换整个应用，不会合并定制代码。设置中的自动更新选项不会绕过此限制。

`BAOCODE_UPDATE_URL` 是保留给主动测试的显式入口；不要在日常启动中设置它。当前下载域名限制和签名验证仍是上游的，不能只改 URL 就当作自己的发布通道。

旧安装需要重新构建并安装后才会应用这项保护。在此之前，请在“设置 → 更新”中关闭更新，不要点击“立即重启更新”。

## 不向上游发送数据

上游的 release 构建每天向 `stats.baocode.dev` 发送一次匿名使用统计，并可在“设置 → 更新 → 诊断日志”上传日志给上游开发者。本 fork 两者默认都关闭：只有设置了 `BAOCODE_TELEMETRY_URL` / `BAOCODE_DIAGNOSTICS_URL` 才会发送到所指的地址，诊断日志一项也随之隐藏。

## 分享给别人

本项目为 GPL-3.0。发布一个版本：提交并推送后，打 `v<版本>-fork.<序号>` 的 tag 并推送（如 `git tag v1.4.0-fork.3 && git push origin v1.4.0-fork.3`）。`.github/workflows/fork-release.yml` 会在 GitHub Actions 上构建 Apple 芯片与 Intel 两个 dmg，启动检查后发布到本仓库的 Releases，附 `LICENSE`、源码归档与安装说明，别人从 Releases 页下载即可。上游的 `release.yml` 不会被这类 tag 触发。

远程服务端版本写在该 workflow 的 `REMOTE_RELEASE` 中，须与 `packages/bao_remote` 对应的官方发布一致（见[上游更新审查](upstream-review.md)）。

自己打包后直接发给别人时：

1. 应用必须由已提交并推送的代码构建，并为该提交打 tag，把 tag 的链接一起发过去，作为对应源码。
2. 把仓库根目录的 `LICENSE` 和应用放在同一个压缩包里。
3. 应用是 ad hoc 签名，对方首次打开前需运行 `xattr -dr com.apple.quarantine /Applications/Baogong.app`。
4. 告诉对方：可与官方 BaoCode 同时安装，但两者共用数据，不要同时打开；有问题找你，不要报给官方。

## 审查上游后合并

当前候选与合并注意事项见[上游更新审查](upstream-review.md)。

1. 先提交并推送自己的改动，保持工作区干净。
2. `git fetch upstream --no-tags`，用 `git log --oneline HEAD..upstream/main` 和 `git show <提交>` 审查更新。
3. 在独立分支中选择性 `git cherry-pick <提交>`；需要整批更新时才考虑 merge。
4. 检查定制行为没有被覆盖，运行相关测试后再合入 main、重新构建安装。

不要直接用 GitHub 的 Sync fork 覆盖尚未审查的更新。尤其保留 pi/Codex 接入、请求 TPS 计量、macOS 标题栏点击修复，以及移除 GitHub Star 请求的定制。

macOS 打包参见 `tool/build_macos.dart`。应用中必须包含 `Contents/Resources/remote/VERSION` 和 `servers.json`；单独运行 `flutter build macos --release` 不会生成这两份资源。
