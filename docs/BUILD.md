# 构建 / 打包 / 安装速查

Eureka 用 SwiftPM + Command Line Tools（无需完整 Xcode），零第三方依赖。所有命令在仓库根目录执行。

## 一句话：开发完新功能后直接打包上线

```bash
make install
```

`make install` 会自动串起：`release`（release 构建）→ `app`（打包 `dist/Eureka.app` + ad-hoc 签名）→ 拷贝到 `~/Applications/Eureka.app`。装完直接从启动台/`~/Applications` 打开即可。

## Makefile 目标一览

| 命令 | 作用 |
|---|---|
| `make build` | debug 构建（`swift build`），最快，日常改代码用 |
| `make test` | 跑全部单测（`swift run eureka-tests`，一个手写 harness，约 136 个） |
| `make run` | dev 模式直接跑 GUI（`swift run eureka`），验证交互 |
| `make release` | release 构建（`swift build -c release`） |
| `make app` | release + `Scripts/build-app.sh` → `dist/Eureka.app`（ad-hoc 签名） |
| `make install` | `app` + 覆盖安装到 `~/Applications/Eureka.app` |
| `make demo` | `Scripts/demo-island.sh`，注入假事件演示灵动岛各状态 |
| `make clean` | `rm -rf .build dist` |

## 推荐的开发→上线流程

```bash
make build      # 1. 改完代码先编译过
make test       # 2. 跑测试，全绿再继续（新增功能记得补 suite 并在 Tests/EurekaTestsRunner/main.swift 注册）
make run        # 3. dev 跑一遍，手动点一下受影响的 tab 验证交互（可选）
make install    # 4. 打包 + 安装到 ~/Applications，日常使用
```

只想重新打包一份 app（不装）：`make app`，产物在 `dist/Eureka.app`。

## 说明与常见提示

- **版本号**：`build-app.sh` 用当前 git 提交号打标（如 `版本 1cb900c`）。要让版本号跟上新功能，先 `git commit` 再 `make app/install`。
- **ad-hoc 签名**：本地打包是 ad-hoc 签名（非 Developer ID）。首次打开若被 Gatekeeper 拦，右键「打开」一次即可；重新签名后 Keychain 读取走 `/usr/bin/security` 子进程，不会反复弹 ACL 授权。
- **`xcrun: unable to lookup item 'PlatformPath'` 警告**：CLT 环境下的无害 SDK 查找噪声，不影响构建产物，可忽略。
- **跑单个测试**：runner 无过滤参数，临时在 `Tests/EurekaTestsRunner/main.swift` 里注释掉其它 `xxxTests(t)` 调用即可只跑子集。
- **DB 迁移**：`Schema.version` 递增后，派生表（usage/scan/session_stats）会 drop 重建下轮重扫；`task_history` 是真实历史，只能走幂等 `ALTER`（见 `Sources/EurekaStore/Schema.swift`）。升级后首次 `make run` 或任意开库的 CLI（如 `swift run eureka --usage-snapshot`）会触发迁移。

## 调试用 CLI（不起 GUI）

```bash
swift run eureka --hooks-status            # Claude hooks + Codex notify 安装状态
swift run eureka --usage-snapshot          # 全量扫描 → 今日用量 JSON（也会触发 DB 迁移）
swift run eureka --limits-snapshot --claude # 限额快照（--claude 额外打非官方 API）
swift run eureka --render-previews [dir]    # 离屏渲染灵动岛各状态到 PNG
swift run eureka-relay inject --event stop --session demo  # 往 spool 注入测试事件
```
