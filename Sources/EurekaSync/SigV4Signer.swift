import CryptoKit
import Foundation

/// AWS Signature V4 signer (pure functions, no IO).
/// Tencent Cloud COS's S3-compatible endpoint shares the same algorithm as AWS S3: service is
/// always "s3",
/// region is injected from config → supporting AWS in phase two is purely a config difference.
/// Intermediate products (canonicalRequest / stringToSign / signingKey) are split out as internal
/// functions
/// so they can be asserted directly against the official AWS test vectors.
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
        public var canonicalPath: String     // already encoded with SyncKeyMapper.canonicalURIPath, with leading /
        public var query: [(String, String)] // always empty in phase one
        public var headers: [String: String] // extra headers; the signer adds host and lowercases/sorts the keys
        public var payloadHash: String       // SHA256 hex (hash of the empty string when there's no body)

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

    /// SHA256 hex of an empty body (for HEAD requests)
    public static let emptyPayloadHash = sha256Hex(Data())

    public static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    /// Signs and returns every header to attach to the request: Authorization, x-amz-date,
    /// x-amz-content-sha256, and the original headers other than host
    public static func sign(
        _ request: RequestToSign, credentials: Credentials,
        region: String, service: String = "s3", date: Date = Date()
    ) -> [String: String] {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        // Headers to sign: host (lowercase) + x-amz-* + caller's extra headers, all keys lowercased
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

    // MARK: - Intermediate products (public for test-vector assertions; pure, no side effects)

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

    /// Derives the signing key via chained HMAC: kSecret → kDate → kRegion → kService → kSigning
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

    /// SigV4 query-parameter encoding (everything outside RFC 3986 unreserved becomes uppercase
    /// %XX)
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

    /// x-amz-date format: yyyyMMdd'T'HHmmss'Z' (UTC)
    static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

extension Data {
    /// Lowercase hex encoding (format of SigV4 digests and HMAC output)
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
