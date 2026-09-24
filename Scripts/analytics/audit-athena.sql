-- 审计归档（Parquet）的 Athena / Trino 外部表：分区投影，不用 MSCK REPAIR。
-- 把 <bucket>/<prefix> 换成备份设置里的存储桶与前缀；host 是各设备的命名空间（备份页可见）。
-- 路径：s3://<bucket>/<prefix>/<host>/eureka/audit/dt=YYYY-MM-DD/part-0000.parquet
CREATE EXTERNAL TABLE IF NOT EXISTS eureka_audit (
    event_id        string,
    source          string,
    session_id      string,
    ts              timestamp,
    kind            string,
    tool            string,
    detail          string,   -- 已脱敏
    detail_redacted boolean,
    cwd             string,
    exit_code       int,
    is_error        boolean,
    risk_level      int,      -- 0 无 / 1 提示 / 2 高危
    risk_rule       string,
    app_version     string
)
PARTITIONED BY (host string, dt string)
STORED AS PARQUET
LOCATION 's3://<bucket>/<prefix>/'
TBLPROPERTIES (
    'projection.enabled'        = 'true',
    'projection.host.type'      = 'injected',
    'projection.dt.type'        = 'date',
    'projection.dt.format'      = 'yyyy-MM-dd',
    'projection.dt.range'       = '2026-01-01,NOW',
    'storage.location.template' = 's3://<bucket>/<prefix>/${host}/eureka/audit/dt=${dt}/'
);
-- 注：文件里本身也有 host 列，与分区列同名时 Athena 以分区列为准；这里的列定义里省去了它。
-- injected 分区要求查询带 host 条件：WHERE host = '<设备>' AND dt >= '2026-09-01'

-- 示例：近 7 天各设备高危命令
-- SELECT host, dt, source, tool, risk_rule, detail
-- FROM eureka_audit
-- WHERE host = '<设备>' AND dt >= date_format(current_date - interval '7' day, '%Y-%m-%d')
--   AND risk_level = 2
-- ORDER BY ts DESC;
