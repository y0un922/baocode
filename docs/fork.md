# 自用 fork

本仓库是 [`y0un922/baocode`](https://github.com/y0un922/baocode)，上游为 [`baocode-dev/baocode`](https://github.com/baocode-dev/baocode)。

## 更新方式

本 fork **默认不启用安装包更新**，包括 release 构建。官方安装包会替换整个应用，不会合并定制代码。设置中的自动更新选项不会绕过此限制。

`BAOCODE_UPDATE_URL` 是保留给主动测试的显式入口；不要在日常启动中设置它。当前下载域名限制和签名验证仍是上游的，不能只改 URL 就当作自己的发布通道。

旧安装需要重新构建并安装后才会应用这项保护。在此之前，请在“设置 → 更新”中关闭更新，不要点击“立即重启更新”。

## 审查上游后合并

1. 先提交并推送自己的改动，保持工作区干净。
2. `git fetch upstream --no-tags`，用 `git log --oneline HEAD..upstream/main` 和 `git show <提交>` 审查更新。
3. 在独立分支中选择性 `git cherry-pick <提交>`；需要整批更新时才考虑 merge。
4. 检查定制行为没有被覆盖，运行相关测试后再合入 main、重新构建安装。

不要直接用 GitHub 的 Sync fork 覆盖尚未审查的更新。尤其保留 pi/Codex 接入、请求 TPS 计量、macOS 标题栏点击修复，以及移除 GitHub Star 请求的定制。

macOS 打包参见 `tool/build_macos.dart`。应用中必须包含 `Contents/Resources/remote/VERSION` 和 `servers.json`；单独运行 `flutter build macos --release` 不会生成这两份资源。
