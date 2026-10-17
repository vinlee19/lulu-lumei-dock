import EurekaKit
import Foundation

/// Object-storage provider presets: determine the endpoint domain template and display copy.
/// All go through the same S3-compatible API + SigV4 signing (S3Client is unaware of provider
/// differences);
/// adding a provider = one more case + a domain template.
public enum StorageProvider: String, CaseIterable, Sendable {
    case tencentCOS = "tencent-cos"
    /// Reserved: Alibaba Cloud OSS S3-compatible endpoint (untested, not in Settings yet)
    case alibabaOSS = "alibaba-oss"
    /// Reserved: Amazon S3 (untested, not in Settings yet)
    case amazonS3 = "amazon-s3"
    /// Reserved: Google Cloud Storage HMAC interoperability (untested, not in Settings yet)
    case googleGCS = "google-gcs"
    case custom = "custom"

    public var displayName: String {
        switch self {
        case .tencentCOS: return L10n.text("Tencent Cloud COS", zhHans: "腾讯云 COS")
        case .alibabaOSS: return L10n.text("Alibaba Cloud OSS", zhHans: "阿里云 OSS")
        case .amazonS3: return "Amazon S3"
        case .googleGCS: return "Google Cloud Storage"
        case .custom: return L10n.text("Custom S3-compatible", zhHans: "自定义 S3 兼容")
        }
    }

    /// endpoint host template (no bucket prefix, no scheme); custom returns nil = user fills it in
    public func endpointHost(region: String) -> String? {
        switch self {
        case .tencentCOS: return "cos.\(region).myqcloud.com"
        case .alibabaOSS: return "oss-\(region).aliyuncs.com"
        case .amazonS3: return "s3.\(region).amazonaws.com"
        case .googleGCS: return "storage.googleapis.com"
        case .custom: return nil
        }
    }

    /// Placeholder hint for the region field
    public var regionHint: String {
        switch self {
        case .tencentCOS: return L10n.text("e.g. ap-guangzhou", zhHans: "如 ap-guangzhou")
        case .alibabaOSS: return L10n.text("e.g. cn-hangzhou", zhHans: "如 cn-hangzhou")
        case .amazonS3: return L10n.text("e.g. us-east-1", zhHans: "如 us-east-1")
        case .googleGCS: return L10n.text("e.g. auto", zhHans: "如 auto")
        case .custom: return L10n.text("Region for SigV4 signing", zhHans: "SigV4 签名用的 region")
        }
    }

    /// Options selectable in Settings for phase one; the other cases are architectural
    /// reservations, add them once verified
    public static var selectable: [StorageProvider] { [.tencentCOS, .custom] }
}
