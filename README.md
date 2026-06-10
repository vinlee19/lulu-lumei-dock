# Eureka

macOS 菜单栏应用：监控本地 **Claude Code** 与 **Codex CLI** 任务，以「灵动岛」风格在屏幕顶部通知——

- 任务运行中：顶部常驻小胶囊（任务数 + 计时）
- 任务完成 / 等待确认 / 出错：展开卡片显示任务简述与耗时，数秒后自动收起（悬停暂停）
- 菜单栏面板：最近任务历史、今日/本周 token 用量与估算费用、订阅限额余量（5h / 周窗口）
- 一键安装/卸载 Claude Code hooks 与 Codex notify 配置（写入前自动备份）

## 环境要求

- macOS 14+（Apple Silicon）
- Swift 5.10 工具链（Command Line Tools 即可，无需完整 Xcode）

## 常用命令

```bash
make build      # 编译
make test       # 运行测试（自建 runner，CLT 无 XCTest）
make run        # 以开发模式运行（swift run eureka）
make app        # 打包 dist/Eureka.app（ad-hoc 签名）
make install    # 安装到 ~/Applications
make demo       # 注入伪造事件，演示灵动岛各场景
```

## 架构

见 [docs/design.md](docs/design.md)。要点：hooks/notify 只调用一个静默的 `eureka-relay`，
它把事件原子写入 spool 目录；应用监听目录消费事件驱动 `TaskStore` 状态机；
灵动岛与菜单栏 UI 都是状态机的投影。用量/限额全部来自本地会话文件解析
（Claude 订阅限额可选启用非官方接口，失效自动隐藏）。
