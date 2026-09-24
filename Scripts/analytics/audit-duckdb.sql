-- 审计归档（Parquet）用 DuckDB 直接查（本地或服务器；S3 凭证走环境变量，不写进文件）。
-- 用法：duckdb -c ".read audit-duckdb.sql"
-- S3 兼容存储（如腾讯 COS）：先设置 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION，
-- 并按需 SET s3_endpoint='cos.<region>.myqcloud.com'; SET s3_url_style='vhost';
INSTALL httpfs; LOAD httpfs;
CREATE OR REPLACE SECRET eureka_s3 (TYPE s3, PROVIDER credential_chain);

CREATE OR REPLACE VIEW audit AS
SELECT * FROM read_parquet(
    's3://<bucket>/<prefix>/*/eureka/audit/dt=*/*.parquet',
    hive_partitioning = true);   -- 自动带出 dt 分区列；设备名在文件内的 host 列

-- ① 每天每个 agent 的操作量与高危次数
SELECT dt, source, count(*) AS ops, count(*) FILTER (WHERE risk_level = 2) AS high_risk
FROM audit GROUP BY 1, 2 ORDER BY 1 DESC, 3 DESC;

-- ② 命中最多的风险规则
SELECT risk_rule, count(*) AS hits FROM audit
WHERE risk_rule IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;

-- ③ 失败率最高的工具（至少 20 次调用）
SELECT tool, count(*) AS calls, round(avg(is_error::int) * 100, 1) AS error_pct
FROM audit GROUP BY 1 HAVING count(*) >= 20 ORDER BY 3 DESC LIMIT 20;
