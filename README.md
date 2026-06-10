# Eureka

macOS 菜单栏应用：监控本地 **Claude Code** 与 **Codex CLI** 任务，以「灵动岛」风格在屏幕顶部通知——

- 任务运行中：顶部常驻小胶囊（任务数 + 计时）
- 任务完成 / 等待确认 / 出错：展开卡片显示任务简述与耗时，数秒后自动收起（悬停暂停）
- 菜单栏面板：最近任务历史、今日/本周 token 用量与估算费用、订阅限额余量（5h / 周窗口）
- 一键安装/卸载 Claude Code hooks 与 Codex notify 配置（写入前自动备份）

## 环境要求

- macOS 14+（Apple Silicon）
- Swift 5.10 工具链（Command Line Tools 即可，无需完整 Xcode）

## 快速上手

```bash
make install    # 打包并安装到 ~/Applications
open ~/Applications/Eureka.app
```

首次启动会自动打开设置页 → 点「一键安装/更新」写入 Claude hooks 与 Codex notify
（写入前自动备份，可随时「全部卸载」恢复）。之后任何 claude / codex 任务都会出现在灵动岛上。

- **菜单栏**：左键打开面板（历史 / 用量 / 限额 / 设置），右键退出
- **灵动岛**：任务运行中常驻小胶囊（计数 + 计时）；完成/出错弹卡自动收起（悬停暂停）；
  等待权限确认时橙色卡片常驻直到处理；点击胶囊展开任务列表
- **Claude 订阅限额**：限额页手动开启（非官方接口）；首次会弹一次钥匙串授权，选「始终允许」

## 开发命令

```bash
make build      # 编译
make test       # 运行测试（自建 runner，CLT 无 XCTest）
make run        # 以开发模式运行（swift run eureka）
make app        # 打包 dist/Eureka.app（ad-hoc 签名）
make demo       # 注入伪造事件，演示灵动岛各场景
Scripts/check-usage-against-ccusage.sh   # 用量统计与 ccusage 对拍
.build/debug/eureka --help               # CLI（hooks 装卸/状态/快照/离屏渲染）
```

## 架构

见 [docs/design.md](docs/design.md)。要点：hooks/notify 只调用一个静默的 `eureka-relay`，
它把事件原子写入 spool 目录；应用监听目录消费事件驱动 `TaskStore` 状态机；
灵动岛与菜单栏 UI 都是状态机的投影。用量/限额全部来自本地会话文件解析
（Claude 订阅限额可选启用非官方接口，失效自动隐藏）。
