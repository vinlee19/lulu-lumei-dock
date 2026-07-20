# 构建 / 打包 / 发布速查

项目使用 SwiftPM + Command Line Tools；应用 target 的唯一第三方依赖是精确锁定的 Sparkle 2.9.2。
所有命令在仓库根目录执行。

## 日常开发与本地安装

```bash
make build
make test
make app
make install
```

| 命令 | 作用 |
|---|---|
| `make build` | debug 构建 |
| `make test` | 运行全部手写测试（当前 300 项） |
| `make run` | 开发模式直接跑 GUI；不会启动 Sparkle 更新检查 |
| `make release` | release 构建 |
| `make app` | 构建并组装 `dist/lulu-lumei-dock.app`，嵌入 Sparkle、逐层 ad-hoc 签名并冒烟验证 |
| `make package-release` | 生成 `dist/lulu-lumei-dock-<版本>.zip` 和带 archive EdDSA 签名的 `dist/appcast.xml` |
| `make install` | 覆盖安装到 `/Applications/lulu-lumei-dock.app` |
| `make demo` | 注入假事件演示灵动岛各状态 |
| `make clean` | 删除 `.build` 与 `dist` |

版本的唯一来源是仓库根目录 `VERSION`。内容必须是纯数字点分格式（如 `0.1.5`），发布 tag 必须
严格等于 `v` + 该版本。`CFBundleShortVersionString` 和 `CFBundleVersion` 都写纯数字版本，不能写
`v`、commit hash 或 `-dirty` 后缀。

## Sparkle 密钥（一次性）

首次启用发布时运行：

```bash
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.vinlee.eureka
```

该命令把私钥保存在本机登录钥匙串，只输出公钥。公钥必须写入
`Scripts/Info.plist.template` 的 `SUPublicEDKey`；私钥严禁提交、粘贴到日志或放进普通文件。

确认 `gh auth status` 正常后，把钥匙串私钥写入 GitHub Actions Secret：

```bash
Scripts/configure-sparkle-secret.sh
```

脚本仅使用权限为 0600 的临时文件，上传为 `SPARKLE_EDDSA_PRIVATE_KEY` 后立即删除临时文件。

## 正式发布

1. 更新 `VERSION`，完成变更并推送。
2. 本地运行 `make test` 和 `make package-release`。
3. 创建并推送稳定 tag，例如 `git tag v0.1.5 && git push origin v0.1.5`。
4. `.github/workflows/release.yml` 在 `macos-15` arm64 runner 上重跑测试、构建、签名、appcast 和
   冒烟验证；所有门禁通过后，最后一步才创建公开 GitHub Release，并且只上传 ZIP 与 appcast 两项资产。
5. 发布后下载公开资产，核对 plist 版本、enclosure URL/长度/EdDSA 签名与 ZIP SHA-256。
6. 用 Release ZIP 的实际 SHA 更新并推送 `vinlee19/homebrew-tap`，再执行 `brew fetch` / `brew install`。

`v0.1.4` 没有 Sparkle，用户必须最后一次通过 Homebrew 或 Release 手动升级到 `v0.1.5`。

## 发布前人工更新闭环

ad-hoc 签名不等同于 Developer ID。`v0.1.5` 发布前必须用本地 HTTP feed 和两个数字版本测试包走完：

- 启动自动发现与「检查更新…」手动检查；
- EdDSA 验签、下载、用户确认安装、替换、退出和重启；
- 关闭自动检查后启动不联网；无更新、离线与重复点击的标准界面行为；
- 更新后 `~/Library/Application Support/Eureka/` 数据与稳定 relay 路径保持不变。

自动化脚本会检查 framework 符号链接、`@rpath`、内部 XPC/Updater/framework/relay/外层 app 的
签名、`codesign --verify --deep --strict`、打包后资源启动、appcast XML、下载 URL、archive 长度及
EdDSA archive 签名。涉及点击确认和重启的最后一段必须在真实安装目录人工执行。

## 调试 CLI

```bash
swift run eureka --hooks-status
swift run eureka --usage-snapshot
swift run eureka --limits-snapshot --claude
swift run eureka --render-previews [dir]
swift run eureka-relay inject --event stop --session demo
```

CLI 与 `swift run` 模式不会启动 Sparkle updater。
