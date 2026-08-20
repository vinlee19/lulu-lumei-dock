-- 数据湖零成本验证：对 eureka-snapshot.sqlite 跑一组示例分析
-- 用法：duckdb -c ".read bootstrap.sql"（快照放当前目录）
INSTALL sqlite; LOAD sqlite;
ATTACH 'eureka-snapshot.sqlite' AS e (TYPE sqlite);

-- ① 近 30 天：按日 × 源的 token 用量
SELECT
    strftime(to_timestamp(ts), '%Y-%m-%d') AS day,
    source,
    sum(input_tokens + output_tokens + cache_creation_tokens
        + cache_creation_1h_tokens + cache_read_tokens) AS total_tokens
FROM e.usage_records
WHERE to_timestamp(ts) > now() - INTERVAL 30 DAY
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;

-- ② 模型分布：各模型的调用次数与输出 token（全时段 Top 20）
SELECT model, count(*) AS calls, sum(output_tokens) AS output_tokens
FROM e.usage_records
GROUP BY 1
ORDER BY 3 DESC
LIMIT 20;

-- ③ 项目时间分配：近 30 天各项目的任务数与总时长（小时）
SELECT
    coalesce(cwd, '(未知)') AS project,
    count(*) AS tasks,
    round(sum(finished_at - coalesce(started_at, finished_at)) / 3600, 1) AS hours
FROM e.task_history
WHERE to_timestamp(finished_at) > now() - INTERVAL 30 DAY
GROUP BY 1
ORDER BY 3 DESC
LIMIT 20;

-- ④ 任务结局分布：按源 × outcome
SELECT source, outcome, count(*) AS tasks
FROM e.task_history
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- ⑤ 工具/技能热榜：近 30 天调用次数 Top 30
SELECT kind, name, sum(count) AS calls
FROM e.tool_calls
WHERE day > strftime(now() - INTERVAL 30 DAY, '%Y-%m-%d')
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 30;
