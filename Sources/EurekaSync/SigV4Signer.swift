import CryptoKit
import Foundation

/// AWS Signature V4 签名器（纯函数，无 IO）。
/// 腾讯云 COS 的 S3 兼容端点与 AWS S3 共用同一套算法：service 固定 "s3"，
/// region 由配置注入 → 二期支持 AWS 是纯配置差异。
/// 中间产物（canonicalRequest / stringToSign / signingKey）拆成 internal 函数，
/// 便于直接对 AWS 官方测试向量断言。
public enum SigV4Signer {
    public struct Credentials {
        public var accessKey: String
        public var secretKey: String

        public init(accessKey: String, secretKey: String) {
            self.accessKey = accessKey
            self.secretKey = secretKey
        }
    }

    public struct RequestToSign {
        public var method: String            // "PUT" / "HEAD"
        public var host: String
        public var canonicalPath: String     // 已按 SyncKeyMapper.canonicalURIPath 编码，含前导 /
        public var query: [(String, String)] // 首期恒为空
        public var headers: [String: String] // 额外头；host 由签名器补，键小写化/排序由签名器做
        public var payloadHash: String       // SHA256 hex（无 body 用空串哈希）

        public init(
            method: String, host: String, canonicalPath: String,
            query: [(String, String)] = [], headers: [String: String] = [:],
            payloadHash: String
        ) {
            self.method = method
            self.host = host
            self.canonicalPath = canonicalPath
            self.query = query
            self.headers = headers
            self.payloadHash = payloadHash
        }
    }

    /// 空 body 的 SHA256 hex（HEAD 请求用）
    public static let emptyPayloadHash = sha256Hex(Data())

    public static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    /// 签名并返回需附加到请求上的全部头：Authorization、x-amz-date、x-amz-content-sha256、host 外的原有头
    public static func sign(
        _ request: RequestToSign, credentials: Credentials,
        region: String, service: String = "s3", date: Date = Date()
    ) -> [String: String] {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        // 待签名头集合：host（小写）+ x-amz-* + 调用方额外头，键统一小写
        var headers: [String: String] = [:]
        for (key, value) in request.headers {
            headers[key.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        headers["host"] = request.host.lowercased()
        headers["x-amz-date"] = amzDate
        headers["x-amz-content-sha256"] = request.payloadHash

        let canonical = canonicalRequest(
            method: request.method, path: request.canonicalPath,
            query: request.query, headers: headers, payloadHash: request.payloadHash)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let toSign = stringToSign(amzDate: amzDate, scope: scope, canonicalRequest: canonical)
        let key = signingKey(
            secretKey: credentials.secretKey, dateStamp: dateStamp,
            region: region, service: service)
        let signature = hmacHex(key: key, message: toSign)
        let signedHeaders = headers.keys.sorted().joined(separator: ";")

        var result = headers
        result["authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"
        return result
    }

    // MARK: - 中间产物（public 供测试向量断言，纯函数无副作用）

    public static func canonicalRequest(
        method: String, path: String, query: [(String, String)],
        headers: [String: String], payloadHash: String
    ) -> String {
        var encodedQuery: [(String, String)] = []
        for (name, value) in query {
            encodedQuery.append((uriEncode(name), uriEncode(value)))
        }
        encodedQuery.sort { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let canonicalQuery = encodedQuery
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        let sortedKeys = headers.keys.sorted()
        let canonicalHeaders = sortedKeys.map { "\($0):\(headers[$0] ?? "")\n" }.joined()
        let signedHeaders = sortedKeys.joined(separator: ";")
        return [
            method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")
    }

    public static func stringToSign(amzDate: String, scope: String, canonicalRequest: String) -> String {
        [
            "AWS4-HMAC-SHA256", amzDate, scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
    }

    /// 链式 HMAC 派生签名密钥：kSecret → kDate → kRegion → kService → kSigning
    public static func signingKey(
        secretKey: String, dateStamp: String, region: String, service: String
    ) -> Data {
        let kDate = hmac(key: Data("AWS4\(secretKey)".utf8), message: dateStamp)
        let kRegion = hmac(key: kDate, message: region)
        let kService = hmac(key: kRegion, message: service)
        return hmac(key: kService, message: "aws4_request")
    }

    public static func hmac(key: Data, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    public static func hmacHex(key: Data, message: String) -> String {
        hmac(key: key, message: message).hexString
    }

    /// SigV4 查询参数编码（RFC 3986 unreserved 之外全部 %XX 大写）
    public static func uriEncode(_ value: String) -> String {
        var result = ""
        for byte in Array(value.utf8) {
            let scalar = Unicode.Scalar(byte)
            if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || scalar == "-" || scalar == "." || scalar == "_" || scalar == "~" {
                result.append(Character(scalar))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// x-amz-date 格式：yyyyMMdd'T'HHmmss'Z'（UTC）
    static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

extension Data {
    /// 小写 hex 编码（SigV4 摘要与 HMAC 输出格式）
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
