#!/usr/bin/env python3
"""Regenerates Tests/EurekaTestsRunner/Fixtures/parquet/*.parquet with pyarrow.

These files are written by an independent Parquet implementation so ParquetReaderTests can prove
our reader decodes files it did not write. The expected values live in ParquetReaderTests.swift
(`expectedFixture`); keep the two in sync. Not part of the build; only needed when fixtures change.

    python3 -m venv /tmp/pq && /tmp/pq/bin/pip install pyarrow && /tmp/pq/bin/python Scripts/gen-parquet-fixtures.py
"""
import datetime as dt
import os

import pyarrow as pa
import pyarrow.parquet as pq

OUT = os.path.join(os.path.dirname(__file__), "..", "Tests", "EurekaTestsRunner", "Fixtures", "parquet")
os.makedirs(OUT, exist_ok=True)

n = 21  # > 16 so definition levels need mixed RLE / bit-packed runs
names = [f"名称-{i}" if i % 3 else None for i in range(n)]
names[4] = ""  # empty string is distinct from null
names[5] = "emoji 🎉 and\nnewline"
ts = [
    dt.datetime(2026, 9, 30, 12, 0, 0, 123456, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=i) if i % 4 else None
    for i in range(n)
]
ts[0] = dt.datetime(1969, 12, 31, 23, 59, 59, 999999, tzinfo=dt.timezone.utc)  # -1 microsecond

schema = pa.schema([
    pa.field("id", pa.int32(), nullable=False),
    pa.field("name", pa.string()),
    pa.field("score", pa.int32()),
    pa.field("flag", pa.bool_()),
    pa.field("at", pa.timestamp("us", tz="UTC")),
])
table = pa.table({
    "id": pa.array(range(n), pa.int32()),
    "name": pa.array(names, pa.string()),
    "score": pa.array([None if i % 5 == 0 else (2**31 - 1 if i % 2 else -(2**31)) for i in range(n)], pa.int32()),
    "flag": pa.array([None if i % 6 == 0 else i % 2 == 0 for i in range(n)], pa.bool_()),
    "at": pa.array(ts, pa.timestamp("us", tz="UTC")),
}, schema=schema)

plain = dict(use_dictionary=False, data_page_version="1.0")
pq.write_table(table, f"{OUT}/pyarrow-gzip-plain.parquet", compression="gzip", **plain)
pq.write_table(table, f"{OUT}/pyarrow-none-plain.parquet", compression="none", **plain)
pq.write_table(table, f"{OUT}/pyarrow-gzip-2groups.parquet", compression="gzip", row_group_size=10, use_dictionary=False)
pq.write_table(table, f"{OUT}/pyarrow-snappy-dict.parquet")  # library defaults: Snappy + dictionary (must be rejected)
