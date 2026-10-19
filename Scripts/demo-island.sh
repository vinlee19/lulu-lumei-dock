#!/bin/bash
# 灵动岛演示：用独立 spool 注入各场景事件，肉眼走查视觉与交互。
# 用法: Scripts/demo-island.sh [eureka 可执行文件]
#   不带参数跑 swift build 出的 debug 版；传 /Applications/lulu-lumei-dock.app/Contents/MacOS/eureka 走查已安装的版本。
# 演示实例与本机真实数据隔离：独立的数据库、spool，以及空的 Claude / Codex / opencode 目录 ——
# 否则演示任务会写进真实历史，本机正在跑的会话也会混进岛里。正在运行的 app 请先退出，免得两个岛叠在一起。
set -e
cd "$(dirname "$0")/.."

swift build
BIN=.build/debug
APP_BIN=${1:-$BIN/eureka}
SANDBOX=.build/demo-island
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/spool" "$SANDBOX/claude/projects" "$SANDBOX/codex/sessions"
export EUREKA_SPOOL_DIR="$PWD/$SANDBOX/spool"
export EUREKA_DB_PATH="$PWD/$SANDBOX/eureka.sqlite"
export EUREKA_CLAUDE_HOME="$PWD/$SANDBOX/claude"
export EUREKA_CLAUDE_PROJECTS="$PWD/$SANDBOX/claude/projects"
export EUREKA_CODEX_HOME="$PWD/$SANDBOX/codex"
export EUREKA_CODEX_SESSIONS="$PWD/$SANDBOX/codex/sessions"
export EUREKA_OPENCODE_DB="$PWD/$SANDBOX/opencode.db"
LOG=$SANDBOX/demo.log

"$APP_BIN" > "$LOG" 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null || true' EXIT
sleep 2

step() { echo ""; echo "▶ $1"; }

step "单任务开始 → 顶部出现 compact 胶囊（呼吸点 + 计时）"
"$BIN/eureka-relay" inject --event user-prompt-submit --session demo1 --title "重构用户认证模块" --cwd /Users/me/work/auth-service
sleep 5

step "并发 +2 个任务 → 计数变 3"
"$BIN/eureka-relay" inject --event user-prompt-submit --session demo2 --title "修复 CI 失败用例" --cwd /Users/me/work/ci
"$BIN/eureka-relay" inject --event user-prompt-submit --session demo3 --title "写数据管道周报" --cwd /Users/me/work/report
sleep 4

step "demo2 完成 → 展开绿色完成卡，6 秒后自动收回 compact（胶囊多一个绿色 ✓ 未读标记）"
"$BIN/eureka-relay" inject --event stop --session demo2
sleep 9

step "demo3 请求权限 → 橙色等待卡，约 10 秒后自动收回 compact（胶囊保持橙色警示）"
"$BIN/eureka-relay" inject --event notification-permission --session demo3
sleep 13

step "demo3 获批继续跑（心跳）→ 胶囊恢复常色"
"$BIN/eureka-relay" inject --event post-tool-use --session demo3
sleep 4

step "demo1、demo3 相继完成 → 两张完成卡排队逐显"
"$BIN/eureka-relay" inject --event stop --session demo1
"$BIN/eureka-relay" inject --event stop --session demo3
sleep 16

step "没有运行中任务 → 胶囊留下未读完成标记 ✓ 3（不再整个隐藏）"
sleep 3

step "demo1 开始新一轮 → 它的未读被清掉，胶囊回到运行态（✓ 仍在，剩 2 个未读）"
"$BIN/eureka-relay" inject --event user-prompt-submit --session demo1 --title "补认证模块单测" --cwd /Users/me/work/auth-service
sleep 4

step "demo1 再次完成 → 完成卡收起后未读回到 3"
"$BIN/eureka-relay" inject --event stop --session demo1
sleep 9

step "现在点一下胶囊：展开新样式的任务列表（空闲会话 3），未读清零；再点岛外收起 → 岛隐藏"
sleep 15

echo ""
echo "demo 结束。island 状态序列："
grep "island=" "$LOG" | sed 's/\[eureka\] /  /'
echo ""
echo "任务计数序列（unread = 未读完成）："
grep "active=" "$LOG" | sed 's/\[eureka\] /  /'
