import EurekaStore
import EurekaSync
import Foundation

/// 可编程 mock 传输：捕获请求、按 URL 匹配返回
final class MockTransport: HTTPTransport {
    var requests: [(request: URLRequest, body: Data?)] = []
    /// 按 url path 片段匹配的应答；默认 200 空体
    var handler: (URLRequest, Data?) throws -> HTTPReply = { _, _ in
        HTTPReply(status: 200, body: Data(), headers: ["etag": "\"mock-etag\""])
    }

    func send(_ request: URLRequest, body: Data?) throws -> HTTPReply {
        requests.append((request, body))
        return try handler(request, body)
    }
}

func s3ClientTests(_ t: TestRunner) {
    t.suite("S3Client / SyncEngine")

    let credentials = SigV4Signer.Credentials(accessKey: "AKID", secretKey: "SK")

    t.test("StorageProvider 预设：endpoint 域名模板") {
        try expectEqual(
            StorageProvider.tencentCOS.endpointHost(region: "ap-guangzhou"),
            "cos.ap-guangzhou.myqcloud.com")
        try expectEqual(
            StorageProvider.alibabaOSS.endpointHost(region: "cn-hangzhou"),
            "oss-cn-hangzhou.aliyuncs.com")
        try expectEqual(
            StorageProvider.amazonS3.endpointHost(region: "us-east-1"),
            "s3.us-east-1.amazonaws.com")
        try expectEqual(
            StorageProvider.googleGCS.endpointHost(region: "auto"),
            "storage.googleapis.com")
        let custom = StorageProvider.custom.endpointHost(region: "r")
        try expect(custom == nil, "custom 应由用户自填")
        // 首期只开放 COS + 自定义
        try expectEqual(StorageProvider.selectable, [.tencentCOS, .custom])
        // rawValue 稳定（持久化 token）
        try expectEqual(StorageProvider(rawValue: "tencent-cos"), .tencentCOS)
    }

    t.test("putObject：URL 拼接、签名头、payload 哈希、返回 ETag") {
        let transport = MockTransport()
        let client = S3Client(
            config: S3Config(
                region: "ap-guangzhou", bucket: "backup-125",
                endpointHost: StorageProvider.tencentCOS.endpointHost(region: "ap-guangzhou")!),
            credentials: credentials, transport: transport)
        let body = Data("hello".utf8)
        let etag = try client.putObject(key: "eureka/mac/claude/中文.md", data: body)

        try expectEqual(etag, "\"mock-etag\"")
        try expectEqual(transport.requests.count, 1)
        let request = transport.requests[0].request
        try expectEqual(
            request.url?.absoluteString,
            "https://backup-125.cos.ap-guangzhou.myqcloud.com/eureka/mac/claude/%E4%B8%AD%E6%96%87.md")
        try expectEqual(request.httpMethod, "PUT")
        try expectEqual(transport.requests[0].body, body)
        try expectEqual(
            request.value(forHTTPHeaderField: "x-amz-content-sha256"),
            SigV4Signer.sha256Hex(body))
        let auth = request.value(forHTTPHeaderField: "authorization") ?? ""
        try expect(auth.contains("/ap-guangzhou/s3/aws4_request"), "scope 错误：\(auth)")
    }

    t.test("自定义 endpoint（AWS 形态）与 headBucket") {
        let transport = MockTransport()
        let client = S3Client(
            config: S3Config(region: "us-east-1", bucket: "b", endpointHost: "s3.us-east-1.amazonaws.com"),
            credentials: credentials, transport: transport)
        try client.headBucket()
        try expectEqual(
            transport.requests[0].request.url?.absoluteString,
            "https://b.s3.us-east-1.amazonaws.com/")
        try expectEqual(transport.requests[0].request.httpMethod, "HEAD")
    }

    t.test("非 2xx → S3Error 带状态码与 body 片段") {
        let transport = MockTransport()
        transport.handler = { _, _ in
            HTTPReply(status: 403, body: Data("<Error><Code>AccessDenied</Code></Error>".utf8))
        }
        let client = S3Client(
            config: S3Config(region: "r", bucket: "b", endpointHost: "cos.r.myqcloud.com"),
            credentials: credentials, transport: transport)
        do {
            try client.putObject(key: "k", data: Data())
            throw ExpectationError(description: "应当抛 S3Error")
        } catch let error as S3Error {
            try expectEqual(error.status, 403)
            try expect(error.bodySnippet.contains("AccessDenied"))
        }
    }

    // MARK: - SyncEngine（真实临时目录 + 临时库 + mock 传输）

    func makeEngineFixture(
        transport: MockTransport, limits: SyncEngine.Limits = SyncEngine.Limits()
    ) throws -> (engine: SyncEngine, store: EurekaStore, base: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-engine-\(UUID())")
        let skills = base.appendingPathComponent("skills/demo")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try "skill-a".write(to: skills.appendingPathComponent("SKILL.md"),
                            atomically: true, encoding: .utf8)
        try "note".write(
            to: base.appendingPathComponent("claude-home/memories/n.md", isDirectory: false)
                .createParent(), atomically: true, encoding: .utf8)
        let store = try EurekaStore(
            path: base.appendingPathComponent("state.sqlite"))
        let roots = SyncRoots(
            claudeHome: base.appendingPathComponent("claude-home"),
            claudeProjects: base.appendingPathComponent("nope"),
            claudeSkills: base.appendingPathComponent("skills"),
            codexHome: base.appendingPathComponent("nope"),
            codexSessions: base.appendingPathComponent("nope"),
            codexSkills: base.appendingPathComponent("nope"),
            opencodeSkills: base.appendingPathComponent("nope"),
            opencodeDB: base.appendingPathComponent("nope/opencode.db"),
            grokSkills: base.appendingPathComponent("nope"),
            grokMemory: base.appendingPathComponent("nope"),
            grokSessions: base.appendingPathComponent("nope"),
            kimiSkills: base.appendingPathComponent("nope"),
            kimiSessions: base.appendingPathComponent("nope"),
            claudePlans: base.appendingPathComponent("nope"),
            plansStaging: base.appendingPathComponent("nope"))
        let client = S3Client(
            config: S3Config(region: "r", bucket: "b", endpointHost: "cos.r.myqcloud.com"),
            credentials: credentials, transport: transport)
        let engine = SyncEngine(
            client: client, repo: store.syncState, roots: roots,
            keyPrefix: "e", host: "m", limits: limits)
        return (engine, store, base)
    }

    t.test("重试：网络错误 2 次后成功 → 全部上传成功") {
        let transport = MockTransport()
        var calls = 0
        transport.handler = { _, _ in
            calls += 1
            if calls <= 2 { throw URLError(.networkConnectionLost) }
            return HTTPReply(status: 200, body: Data(), headers: ["etag": "\"e\""])
        }
        var limits = SyncEngine.Limits()
        limits.maxRetries = 2
        limits.retryBackoffSeconds = 0.01  // 测试快速退避
        let fixture = try makeEngineFixture(transport: transport, limits: limits)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let report = fixture.engine.runCycle()
        try expectEqual(report.failed, 0)
        try expectEqual(report.uploaded, 2)  // 首文件重试 2 次后成功，第二个直接成功
        try expectEqual(calls, 4)            // 2 失败 + 2 成功
    }

    t.test("重试：4xx 不重试（权限/键错误重试无意义）") {
        let transport = MockTransport()
        transport.handler = { _, _ in
            HTTPReply(status: 403, body: Data("AccessDenied".utf8))
        }
        var limits = SyncEngine.Limits()
        limits.maxRetries = 3
        limits.retryBackoffSeconds = 0.01
        let fixture = try makeEngineFixture(transport: transport, limits: limits)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let report = fixture.engine.runCycle()
        try expectEqual(report.uploaded, 0)
        try expectEqual(report.failed, 2)
        try expectEqual(transport.requests.count, 2, "4xx 不应产生重试请求")
    }

    t.test("上传记录带来源类目（category 透传到 UploadedFile）") {
        let transport = MockTransport()
        let fixture = try makeEngineFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let report = fixture.engine.runCycle()
        try expectEqual(report.uploaded, 2)
        let categories = Set(report.uploadedFiles.map(\.category))
        try expect(categories.contains("claude/skills"), "缺 claude/skills: \(categories)")
        try expect(categories.contains("claude/memories"), "缺 claude/memories: \(categories)")
    }

    t.test("engine：首轮全传并落库，二轮零上传；进度回调覆盖全程") {
        let transport = MockTransport()
        let (engine, store, base) = try makeEngineFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: base) }

        var snapshots: [SyncProgress] = []
        engine.onProgress = { snapshots.append($0) }
        let first = engine.runCycle()
        try expectEqual(first.uploaded, 2)
        try expectEqual(first.failed, 0)
        try expectEqual(try store.syncState.allEntries().count, 2)
        // 上传文件明细：数量与 uploaded 一致，含文件名
        try expectEqual(first.uploadedFiles.count, 2)
        try expect(first.uploadedFiles.allSatisfy { !$0.name.isEmpty && $0.size >= 0 })
        // 进度：首帧 totalFiles=2 completed=0，末帧 completed=2、字节齐平
        try expect(!snapshots.isEmpty, "应有进度回调")
        try expectEqual(snapshots.first?.totalFiles, 2)
        try expectEqual(snapshots.first?.completedFiles, 0)
        try expectEqual(snapshots.last?.completedFiles, 2)
        try expectEqual(snapshots.last?.transferredBytes, first.uploadedBytes)
        try expect(snapshots.contains { $0.currentFile != nil }, "上传中应报当前文件名")

        let second = engine.runCycle()
        try expectEqual(second.uploaded, 0, "未变化不应重传")
    }

    t.test("engine：单文件 4xx 失败继续，其余成功落库") {
        let transport = MockTransport()
        transport.handler = { request, _ in
            if request.url?.path.contains("SKILL.md") == true {
                return HTTPReply(status: 500, body: Data("boom".utf8))
            }
            return HTTPReply(status: 200, body: Data(), headers: [:])
        }
        let (engine, store, base) = try makeEngineFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: base) }

        let report = engine.runCycle()
        try expectEqual(report.uploaded, 1)
        try expectEqual(report.failed, 1)
        try expect(report.firstError?.contains("500") == true)
        try expectEqual(try store.syncState.allEntries().count, 1)
    }

    t.test("engine：连续网络错误中止余量") {
        let transport = MockTransport()
        transport.handler = { _, _ in throw URLError(.notConnectedToInternet) }
        var limits = SyncEngine.Limits()
        limits.abortAfterConsecutiveNetworkFailures = 2
        let (engine, store, base) = try makeEngineFixture(transport: transport, limits: limits)
        defer { try? FileManager.default.removeItem(at: base) }

        let report = engine.runCycle()
        try expectEqual(report.failed, 2, "达到连续失败阈值即中止")
        try expectEqual(try store.syncState.allEntries().count, 0)
        try expect(report.firstError?.contains("网络错误") == true)
    }

    t.test("engine：盘上消失的文件清 sync_state 行") {
        let transport = MockTransport()
        let (engine, store, base) = try makeEngineFixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: base) }
        try store.syncState.upsert(SyncStateRepo.Entry(
            path: "/ghost/file.md", remoteKey: "k/ghost", size: 1, mtime: 1, uploadedAt: Date()))

        _ = engine.runCycle()
        let ghost = try store.syncState.entry(path: "/ghost/file.md")
        try expect(ghost == nil, "幽灵行应被清理")
    }
}

private extension URL {
    /// 建父目录后返回自身（测试便捷）
    func createParent() throws -> URL {
        try FileManager.default.createDirectory(
            at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
