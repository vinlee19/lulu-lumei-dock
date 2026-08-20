# 服务器侧分析（数据湖零成本验证）

开启云备份后，每轮同步会把 `eureka.sqlite` 的三张分析事实表
（`usage_records` / `task_history` / `tool_calls`）抽取成一个独立快照上传到：

```
<prefix>/<设备命名空间>/eureka/db/eureka-snapshot.sqlite
```

快照只在事实表变化时重建（指纹 = 行数 + 最大 rowid，见 `EurekaDBSnapshot.swift`），
不含任何密钥、全文索引或同步记账表。

## 在服务器上跑分析

任意一台机器，装一个 DuckDB 单二进制即可（无守护进程、无依赖）：

```bash
# 1. 从桶里取快照（以腾讯 COS 的 coscli 为例；S3 兼容端点用 aws cli / rclone 均可）
coscli cp cos://<bucket>/<prefix>/<host>/eureka/db/eureka-snapshot.sqlite ./eureka-snapshot.sqlite

# 2. DuckDB 直接 ATTACH SQLite 快照跑分析
duckdb -c ".read bootstrap.sql"
```

`bootstrap.sql` 假设快照在当前目录。定时刷新用 crontab：

```cron
*/30 * * * * cd /srv/eureka-analytics && ./pull-and-analyze.sh >> analyze.log 2>&1
```

## 表结构速查

- `usage_records(source, model, project, session_id, ts, input_tokens, output_tokens, cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens)` — 每次 API 交互一行，`ts` 为 unix epoch 秒
- `task_history(id, source, session_id, title, cwd, started_at, session_started_at, finished_at, outcome, detail)` — 每个已完结任务一行
- `tool_calls(day, source, kind, name, session_id, count, last_ts, tokens)` — 工具/技能/MCP 调用按日聚合

下一步（P1 数据湖 v0）：客户端导出归一化 JSONL 增量，服务器端 `COPY TO` 分区 Parquet。
