import EurekaStore
import EurekaSync
import Foundation

func eurekaDBSnapshotTests(_ t: TestRunner) {
    t.suite("EurekaDBSnapshot（分析快照）")

    /// 建一个带三张事实表的最小源库
    func makeSourceDB(at url: URL) throws -> SQLiteDB {
        let db = try SQLiteDB(path: url.path)
        try db.execute("""
        CREATE TABLE usage_records (id INTEGER PRIMARY KEY, source TEXT, input_tokens INTEGER);
        CREATE TABLE task_history (id TEXT PRIMARY KEY, source TEXT);
        CREATE TABLE tool_calls (day TEXT, name TEXT, count INTEGER);
        INSERT INTO usage_records (source, input_tokens) VALUES ('claude', 100), ('codex', 200);
        INSERT INTO task_history VALUES ('t1', 'claude');
        INSERT INTO tool_calls VALUES ('2026-08-15', 'Read', 3);
        """)
        return db
    }

    func tempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-dbsnap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    t.test("首次物化：三表整份复制，行数一致") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("eureka.sqlite")
        let snapshot = base.appendingPathComponent("export/eureka-snapshot.sqlite")
        _ = try makeSourceDB(at: src)

        try expect(EurekaDBSnapshot.materializeIfChanged(dbPath: src, snapshotPath: snapshot),
            "首次应重建")
        let out = try SQLiteDB(path: snapshot.path, readOnly: true)
        let usage = try out.query("SELECT count(*) FROM usage_records") { $0.int(0) }.first
        let history = try out.query("SELECT count(*) FROM task_history") { $0.int(0) }.first
        let calls = try out.query("SELECT count(*) FROM tool_calls") { $0.int(0) }.first
        try expectEqual(usage, 2)
        try expectEqual(history, 1)
        try expectEqual(calls, 1)
    }

    t.test("指纹未变：不重建（幂等，mtime 稳定不触发重传）") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("eureka.sqlite")
        let snapshot = base.appendingPathComponent("export/eureka-snapshot.sqlite")
        _ = try makeSourceDB(at: src)

        try expect(EurekaDBSnapshot.materializeIfChanged(dbPath: src, snapshotPath: snapshot))
        try expect(!EurekaDBSnapshot.materializeIfChanged(dbPath: src, snapshotPath: snapshot),
            "无变化不该重建")
    }

    t.test("事实表新增行：指纹变化 → 重建且内容更新") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("eureka.sqlite")
        let snapshot = base.appendingPathComponent("export/eureka-snapshot.sqlite")
        let db = try makeSourceDB(at: src)
        try expect(EurekaDBSnapshot.materializeIfChanged(dbPath: src, snapshotPath: snapshot))

        try db.execute("INSERT INTO usage_records (source, input_tokens) VALUES ('kimi', 50)")
        try expect(EurekaDBSnapshot.materializeIfChanged(dbPath: src, snapshotPath: snapshot),
            "事实表变了应重建")
        let out = try SQLiteDB(path: snapshot.path, readOnly: true)
        let usage = try out.query("SELECT count(*) FROM usage_records") { $0.int(0) }.first
        try expectEqual(usage, 3)
    }

    t.test("记账表改动不触发重建（防「上传→记账→再上传」永动噪音）") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let src = base.appendingPathComponent("eureka.sqlite")
        let snapshot = base.appendingPathComponent("export/eureka-snapshot.sqlite")
        let db = try makeSourceDB(at: src)
        try expect(EurekaDBSnapshot.materializeIfChanged(dbPath: src, snapshotPath: snapshot))

        try db.execute("""
        CREATE TABLE sync_state (path TEXT PRIMARY KEY, size INTEGER);
        INSERT INTO sync_state VALUES ('/a', 1);
        """)
        try expect(!EurekaDBSnapshot.materializeIfChanged(dbPath: src, snapshotPath: snapshot),
            "记账表的写入不该改变指纹")
    }

    t.test("源库缺失：安静返回 false") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try expect(!EurekaDBSnapshot.materializeIfChanged(
            dbPath: base.appendingPathComponent("missing.sqlite"),
            snapshotPath: base.appendingPathComponent("snap.sqlite")))
    }
}
