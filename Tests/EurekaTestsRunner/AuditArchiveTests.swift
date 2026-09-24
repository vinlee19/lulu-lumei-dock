import EurekaKit
import EurekaStore
import EurekaSync
import Foundation

func auditArchiveTests(_ t: TestRunner) {
    t.suite("AuditRedactor")

    t.test("凭证被遮、命令结构保留") {
        let cases: [(String, String)] = [
            ("curl -H 'Authorization: Bearer abcdefghijklmnop' https://x", "abcdefghijklmnop"),
            ("export OPENAI_API_KEY=sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA", "sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA"),
            ("DB_PASSWORD=\"hunter2 x\" ./run.sh", "hunter2"),
            ("mysql -h127.0.0.1 -P9030 -uroot -pS3cret! -e 'select 1'", "S3cret!"),
            ("psql postgres://admin:topsecret@db:5432/app", "topsecret"),
            ("curl 'https://x/api?token=abc123&page=2'", "abc123"),
            ("aws s3 ls # AKIAABCDEFGHIJKLMNOP", "AKIAABCDEFGHIJKLMNOP"),
            ("git remote add o https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/x", "ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
            ("tool --password=pw12345 --verbose", "pw12345"),
            ("echo eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk", "eyJhbGciOiJIUzI1NiJ9"),
        ]
        for (input, secret) in cases {
            let result = AuditRedactor.redact(detail: input, tool: "Bash")
            try expect(result.redacted, "应脱敏：\(input)")
            try expect(!result.text.contains(secret), "残留：\(result.text)")
        }
        let kept = AuditRedactor.redact(detail: "mysql -h127.0.0.1 -P9030 -uroot -pS3cret!", tool: "Bash")
        try expect(kept.text.hasPrefix("mysql -h127.0.0.1 -P9030 -uroot -p"), kept.text)
    }

    t.test("普通命令与代码不误伤") {
        let clean = [
            "git status && make test",
            "python3 -c 'rows.sort(key=lambda r: r[1]); json.dumps(x, sort_keys=True)'",
            "grep -n session_id=abc Sources/*.swift",
            "if api_key == expected: pass",
            "ls -la ~/.ssh",
            "curl https://example.com/docs?page=2&lang=zh",
            "tokens=$(wc -l < file)",
        ]
        for input in clean {
            let result = AuditRedactor.redact(detail: input, tool: "Bash")
            try expect(!result.redacted, "误伤：\(input) → \(result.text)")
        }
    }

    t.test("write_stdin 整段遮掉") {
        let result = AuditRedactor.redact(detail: "my-password\n", tool: "write_stdin")
        try expectEqual(result.text, "[REDACTED stdin]")
        try expect(result.redacted)
    }

    t.suite("ParquetWriter")

    t.test("文件结构：首尾魔数、尾部长度指向元数据") {
        let data = try ParquetWriter.write(columns: [
            .init(name: "a", values: .string(["x", nil, "z"]), required: false),
            .init(name: "b", values: .int32([1, 2, 3]), required: true),
        ], createdBy: "test")
        try expectEqual(Data(data.prefix(4)), Data("PAR1".utf8))
        try expectEqual(Data(data.suffix(4)), Data("PAR1".utf8))
        let lengthBytes = [UInt8](data[(data.count - 8)..<(data.count - 4)])
        let footerLength = Int(lengthBytes[0]) | Int(lengthBytes[1]) << 8
            | Int(lengthBytes[2]) << 16 | Int(lengthBytes[3]) << 24
        try expect(footerLength > 0 && footerLength < data.count - 12, "\(footerLength)")
        // 元数据以 FileMetaData.version 字段开头（字段 1、i32 → 0x15），值 1 的 zigzag = 0x02
        let footer = data[(data.count - 8 - footerLength)...]
        try expectEqual(Array(footer.prefix(2)), [0x15, 0x02])
    }

    t.test("必填列含空值 / 行数不一致 → 报错") {
        do {
            _ = try ParquetWriter.write(columns: [
                .init(name: "a", values: .string(["x", nil]), required: true)], createdBy: "t")
            throw ExpectationError(description: "应拒绝")
        } catch is ParquetWriter.WriteError {}
        do {
            _ = try ParquetWriter.write(columns: [
                .init(name: "a", values: .int32([1]), required: true),
                .init(name: "b", values: .int32([1, 2]), required: true)], createdBy: "t")
            throw ExpectationError(description: "应拒绝")
        } catch is ParquetWriter.WriteError {}
    }

    t.suite("AuditArchive")

    func makeStore() throws -> (EurekaStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try EurekaStore(path: root.appendingPathComponent("eureka.sqlite")), root)
    }

    func event(_ id: String, at seconds: TimeInterval, detail: String = "ls") -> AuditEvent {
        AuditEvent(
            opId: id, source: .codex, sessionId: "s1", timestamp: Date(timeIntervalSince1970: seconds),
            kind: .command, tool: "exec_command", detail: detail, cwd: nil, exitCode: nil,
            isError: false, riskLevel: nil, riskRule: nil)
    }

    t.test("按 UTC 日分区、指纹变化才重写、回填 exit_code 触发重写") {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let day1 = 1_790_000_000.0  // 2026-09-21 UTC
        try store.audit.insert(event("a", at: day1))
        try store.audit.insert(event("b", at: day1 + 86400))
        let out = root.appendingPathComponent("audit")
        var outcome = AuditArchive.materialize(
            store: store, outDir: out, host: "h", appVersion: "t", cutoff: nil)
        try expectEqual(outcome.writtenDays, ["2026-09-21", "2026-09-22"])
        try expect(FileManager.default.fileExists(
            atPath: out.appendingPathComponent("dt=2026-09-21/part-0000.parquet").path))

        outcome = AuditArchive.materialize(store: store, outDir: out, host: "h", appVersion: "t", cutoff: nil)
        try expectEqual(outcome.writtenDays, [])

        try store.audit.markOutcome(source: .codex, sessionId: "s1", opId: "a", exitCode: 1, isError: true)
        outcome = AuditArchive.materialize(store: store, outDir: out, host: "h", appVersion: "t", cutoff: nil)
        try expectEqual(outcome.writtenDays, ["2026-09-21"])
    }

    t.test("未上传不可清理；上传对齐后可清理；保留期外已上传的日期不再重写") {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = 1_790_000_000.0
        try store.audit.insert(event("a", at: old))
        let out = root.appendingPathComponent("audit")
        AuditArchive.materialize(store: store, outDir: out, host: "h", appVersion: "t", cutoff: nil)
        try expect(AuditArchive.prunableDays(store: store).isEmpty, "未上传不应可清理")

        // 模拟备份引擎上传成功：sync_state 记下与本地文件一致的 size+mtime
        let file = out.appendingPathComponent("dt=2026-09-21/part-0000.parquet")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        try store.syncState.upsert(.init(
            path: file.path, remoteKey: "k",
            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            uploadedAt: Date()))
        AuditArchive.reconcileUploads(store: store)
        try expectEqual(AuditArchive.prunableDays(store: store), ["2026-09-21"])

        // 新增一行 → 指纹变了 → 又不可清理，直到重写并再次上传
        try store.audit.insert(event("b", at: old + 60))
        try expect(AuditArchive.prunableDays(store: store).isEmpty)

        // 保留期截止在它之后：已上传过的旧日期不再重写（防止清理后用更少的行覆盖远端）
        let outcome = AuditArchive.materialize(
            store: store, outDir: out, host: "h", appVersion: "t",
            cutoff: Date(timeIntervalSince1970: old + 10 * 86400))
        try expectEqual(outcome.writtenDays, [])
    }

    t.test("上传清单：dt 分区目录进 eureka/audit，临时文件跳过") {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.audit.insert(event("a", at: 1_790_000_000))
        let out = root.appendingPathComponent("audit")
        AuditArchive.materialize(store: store, outDir: out, host: "h", appVersion: "t", cutoff: nil)
        try Data("x".utf8).write(to: out.appendingPathComponent("dt=2026-09-21/.part-0001.parquet.tmp"))
        var roots = try emptySyncRoots(base: root)
        roots.auditArchiveDir = out
        let result = SyncSourceCatalog.enumerate(roots: roots, prefix: "p", host: "h", maxFileSize: 1 << 30)
        let audit = result.candidates.filter { $0.category == "eureka/audit" }
        try expectEqual(audit.map(\.remoteKey), ["p/h/eureka/audit/dt=2026-09-21/part-0000.parquet"])
    }
}

func auditArchivePruneTests(_ t: TestRunner) {
    t.suite("AuditArchive 清理联动")

    func uploadAll(_ store: EurekaStore, _ out: URL) throws {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        for dir in dirs {
            let file = out.appendingPathComponent(dir).appendingPathComponent("part-0000.parquet")
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            try store.syncState.upsert(.init(
                path: file.path, remoteKey: "k/\(dir)",
                size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                uploadedAt: Date()))
        }
        AuditArchive.reconcileUploads(store: store)
    }

    t.test("只整天删除已上传的过期日期；未上传的日期即使过期也保留") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-archive-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EurekaStore(path: root.appendingPathComponent("eureka.sqlite"))
        let base = 1_790_000_000.0  // 2026-09-21
        for (index, offset) in ([0, 86400, 2 * 86400] as [Double]).enumerated() {
            try store.audit.insert(AuditEvent(
                opId: "e\(index)", source: .claude, sessionId: "s", timestamp: Date(timeIntervalSince1970: base + offset),
                kind: .command, tool: "Bash", detail: "ls"))
        }
        let out = root.appendingPathComponent("audit")
        AuditArchive.materialize(store: store, outDir: out, host: "h", appVersion: "t", cutoff: nil)
        // 截止时间落在 9-23 当天中午：9-21、9-22 过期；但都没上传 → 一行都不删
        let cutoff = Date(timeIntervalSince1970: base + 2 * 86400 + 3600)
        try expectEqual(AuditArchive.prune(store: store, cutoff: cutoff, maxRows: 1000), [])
        try expectEqual(try store.audit.totalCount(), 3)

        try uploadAll(store, out)
        try expectEqual(
            AuditArchive.prune(store: store, cutoff: cutoff, maxRows: 1000), ["2026-09-21", "2026-09-22"])
        try expectEqual(try store.audit.totalCount(), 1)  // 截止当天整天保留
    }

    t.test("行数上限：从最旧的已上传日期起整天删") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-archive-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EurekaStore(path: root.appendingPathComponent("eureka.sqlite"))
        let base = 1_790_000_000.0
        for index in 0..<6 {
            try store.audit.insert(AuditEvent(
                opId: "e\(index)", source: .claude, sessionId: "s",
                timestamp: Date(timeIntervalSince1970: base + Double(index / 2) * 86400),
                kind: .command, tool: "Bash", detail: "ls"))
        }
        let out = root.appendingPathComponent("audit")
        AuditArchive.materialize(store: store, outDir: out, host: "h", appVersion: "t", cutoff: nil)
        try uploadAll(store, out)
        try expectEqual(AuditArchive.prune(store: store, cutoff: nil, maxRows: 3), ["2026-09-21", "2026-09-22"])
        try expectEqual(try store.audit.totalCount(), 2)
    }
}
