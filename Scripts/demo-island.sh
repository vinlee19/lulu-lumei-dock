#!/bin/bash
# Dynamic Island demo: injects events for each scenario via a separate spool, for eyeballing visuals
# and interaction.
# Usage: Scripts/demo-island.sh [eureka executable]
#   With no argument it runs the debug build from swift build; pass
#   /Applications/lulu-lumei-dock.app/Contents/MacOS/eureka to walk through the installed version.
# The demo instance is isolated from real local data: its own database and spool, plus empty Claude
# / Codex / opencode directories -- otherwise demo tasks would be written into the real history and
# sessions running on this machine would leak into the island. Quit any running app first so two
# islands don't stack up.
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

step "现在点一下胶囊：展开新样式的任务列表（空闲会话 3），未读清零；再点岛外收起 → 回到胶囊，只显示变暗的空闲来源"
sleep 15

echo ""
echo "demo 结束。island 状态序列："
grep "island=" "$LOG" | sed 's/\[eureka\] /  /'
echo ""
echo "任务计数序列（unread = 未读完成）："
grep "active=" "$LOG" | sed 's/\[eureka\] /  /'
