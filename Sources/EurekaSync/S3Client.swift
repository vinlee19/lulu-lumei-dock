import Foundation

/// S3 兼容存储配置。endpointHost 由调用方给定 —— 预设服务商用
/// StorageProvider.endpointHost(region:) 生成，自定义服务商由用户填写；
/// S3Client 本身不感知服务商差异（纯 S3 协议客户端）。
public struct S3Config: Equatable {
    public var region: String
    public var bucket: String
    /// endpoint host（不含 bucket 前缀、不含 scheme），必填
    public var endpointHost: String

    public init(region: String, bucket: String, endpointHost: String) {
        self.region = region
        self.bucket = bucket
        self.endpointHost = endpointHost
    }

    /// 恒用 virtual-hosted style：https://<bucket>.<endpointHost>/<key>
    public var resolvedHost: String {
        "\(bucket).\(endpointHost)".lowercased()
    }
}

/// S3 层错误：只带状态码 + body 片段（COS 错误体是 XML，原样截断展示、不解析）
public struct S3Error: Error, CustomStringConvertible {
    public var status: Int
    public var bodySnippet: String

    public var description: String { "HTTP \(status): \(bodySnippet)" }

    init(status: Int, body: Data) {
        self.status = status
        let text = String(decoding: body.prefix(600), as: UTF8.self)
        bodySnippet = String(text.prefix(300))
    }
}

/// 最小 S3 客户端：PUT Object + HEAD Bucket（上传-only 首期够用，零 XML 解析）
public final class S3Client {
    private let config: S3Config
    private let credentials: SigV4Signer.Credentials
    private let transport: HTTPTransport

    public init(
        config: S3Config, credentials: SigV4Signer.Credentials,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.config = config
        self.credentials = credentials
        self.transport = transport
    }

    /// PUT Object；成功返回服务端 ETag（可空）。失败 throw S3Error / 传输层错误。
    @discardableResult
    public func putObject(key: String, data: Data) throws -> String? {
        let path = SyncKeyMapper.canonicalURIPath(forKey: key)
        // PUT 超时按体积放宽：基础 60s + 每 MB 5s，封顶 300s
        let megabytes = Double(data.count) / 1_048_576.0
        let timeout: TimeInterval = min(300.0, 60.0 + megabytes * 5.0)
        let reply = try send(
            method: "PUT", path: path, payload: data, timeout: timeout)
        guard (200..<300).contains(reply.status) else {
            throw S3Error(status: reply.status, body: reply.body)
        }
        return reply.headers["etag"]
    }

    /// HEAD Bucket → 测试连接/凭证/桶配置（无响应体，无需 XML）
    public func headBucket() throws {
        let reply = try send(method: "HEAD", path: "/", payload: nil, timeout: 15)
        guard (200..<300).contains(reply.status) else {
            throw S3Error(status: reply.status, body: reply.body)
        }
    }

    private func send(
        method: String, path: String, payload: Data?, timeout: TimeInterval
    ) throws -> HTTPReply {
        let host = config.resolvedHost
        let payloadHash = payload.map { SigV4Signer.sha256Hex($0) }
            ?? SigV4Signer.emptyPayloadHash
        let signed = SigV4Signer.sign(
            SigV4Signer.RequestToSign(
                method: method, host: host, canonicalPath: path, payloadHash: payloadHash),
            credentials: credentials, region: config.region)

        guard let url = URL(string: "https://\(host)\(path)") else {
            throw S3Error(status: 0, body: Data("无效 URL：\(host)\(path)".utf8))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (key, value) in signed {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try transport.send(request, body: payload)
    }
}
