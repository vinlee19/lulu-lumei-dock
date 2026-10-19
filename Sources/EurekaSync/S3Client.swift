import EurekaKit
import Foundation

/// S3-compatible storage config. endpointHost is supplied by the caller: preset providers use
/// StorageProvider.endpointHost(region:), custom providers are filled in by the user;
/// S3Client itself is unaware of provider differences (a pure S3-protocol client).
public struct S3Config: Equatable {
    public var region: String
    public var bucket: String
    /// endpoint host (no bucket prefix, no scheme), required
    public var endpointHost: String

    public init(region: String, bucket: String, endpointHost: String) {
        self.region = region
        self.bucket = bucket
        self.endpointHost = endpointHost
    }

    /// Always virtual-hosted style: https://<bucket>.<endpointHost>/<key>
    public var resolvedHost: String {
        "\(bucket).\(endpointHost)".lowercased()
    }
}

/// S3-layer error: carries only the status code + a body snippet (COS error bodies are XML,
/// shown truncated as-is, not parsed)
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

/// Minimal S3 client: PUT Object + HEAD Bucket (enough for upload-only phase one, zero XML
/// parsing)
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

    /// PUT Object; returns the server's ETag on success (may be nil). Throws S3Error / transport
    /// errors on failure.
    @discardableResult
    public func putObject(key: String, data: Data) throws -> String? {
        let path = SyncKeyMapper.canonicalURIPath(forKey: key)
        // PUT timeout scales with size: 60s base + 5s per MB, capped at 300s
        let megabytes = Double(data.count) / 1_048_576.0
        let timeout: TimeInterval = min(300.0, 60.0 + megabytes * 5.0)
        // Audit-archive Parquet gets its standard type so bucket-side tools recognize it
        // (Content-Type is not part of the SigV4 signature)
        let contentType = key.hasSuffix(".parquet") ? "application/vnd.apache.parquet" : nil
        let reply = try send(
            method: "PUT", path: path, payload: data, timeout: timeout, contentType: contentType)
        guard (200..<300).contains(reply.status) else {
            throw S3Error(status: reply.status, body: reply.body)
        }
        return reply.headers["etag"]
    }

    /// HEAD Bucket → tests the connection/credentials/bucket config (no response body, no XML
    /// needed)
    public func headBucket() throws {
        let reply = try send(method: "HEAD", path: "/", payload: nil, timeout: 15)
        guard (200..<300).contains(reply.status) else {
            throw S3Error(status: reply.status, body: reply.body)
        }
    }

    private func send(
        method: String, path: String, payload: Data?, timeout: TimeInterval,
        contentType: String? = nil
    ) throws -> HTTPReply {
        let host = config.resolvedHost
        let payloadHash = payload.map { SigV4Signer.sha256Hex($0) }
            ?? SigV4Signer.emptyPayloadHash
        let signed = SigV4Signer.sign(
            SigV4Signer.RequestToSign(
                method: method, host: host, canonicalPath: path, payloadHash: payloadHash),
            credentials: credentials, region: config.region)

        guard let url = URL(string: "https://\(host)\(path)") else {
            throw S3Error(status: 0, body: Data(L10n.format("Invalid URL: %@%@", zhHans: "无效 URL：%@%@", String(host), String(path)).utf8))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (key, value) in signed {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return try transport.send(request, body: payload)
    }
}
