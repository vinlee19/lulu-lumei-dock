#!/bin/bash
# 用 ccusage 作 oracle 对拍 Eureka 的 Claude 今日用量统计。
# 口径说明：
# - 两者都按 (requestId, message.id) 去重、本地时区日界
# - ccusage 20.x 的 daily 聚合包含 codex，对拍只取 modelBreakdowns 中 claude-* 模型
# - 活跃会话持续写 transcript，两次扫描存在固有漂移 → 先跑 ccusage 后跑 Eureka，容差 3%
set -e
cd "$(dirname "$0")/.."

swift build > /dev/null 2>&1 || swift build

echo "== ccusage（oracle）=="
npx -y ccusage@latest daily --json > /tmp/ccusage.json 2>/dev/null

echo "== Eureka 扫描（独立临时库）=="
export EUREKA_DB_PATH=$(mktemp -d)/oracle.sqlite
.build/debug/eureka --usage-snapshot > /tmp/eureka-usage.json

python3 - <<'EOF'
import json, datetime

today = datetime.date.today().isoformat()

cc_data = json.load(open('/tmp/ccusage.json'))
rows = [d for d in cc_data.get('daily', []) if d.get('period') == today]
if not rows:
    print(f"ccusage 没有今日({today})数据，可用 period: ",
          [d.get('period') for d in cc_data.get('daily', [])][-3:])
    raise SystemExit(1)
breakdowns = [b for b in rows[0].get('modelBreakdowns', [])
              if b.get('modelName', '').startswith('claude')]
cc = {
    'input': sum(b['inputTokens'] for b in breakdowns),
    'output': sum(b['outputTokens'] for b in breakdowns),
    'cacheCreate': sum(b['cacheCreationTokens'] for b in breakdowns),
    'cacheRead': sum(b['cacheReadTokens'] for b in breakdowns),
}
print("ccusage 今日 Claude:", cc)

data = json.load(open('/tmp/eureka-usage.json'))
claude = [r for r in data['today'] if r['source'] == 'claude']
ours = {
    'input': sum(r['inputTokens'] for r in claude),
    'output': sum(r['outputTokens'] for r in claude),
    'cacheCreate': sum(r['cacheCreationTokens'] for r in claude),
    'cacheRead': sum(r['cacheReadTokens'] for r in claude),
}
print("Eureka  今日 Claude:", ours)
print()
ok = True
for key in cc:
    a, b = ours[key], cc[key]
    diff = abs(a - b) / max(b, 1)
    status = "✓" if diff < 0.03 else "✗"
    if diff >= 0.03: ok = False
    print(f"  {status} {key:12s} eureka={a:>13,} ccusage={b:>13,} 偏差 {diff:.2%}")
print()
print("对拍" + ("通过（偏差 < 3%）" if ok else "失败"))
raise SystemExit(0 if ok else 1)
EOF
