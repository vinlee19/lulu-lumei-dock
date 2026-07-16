import Foundation

/// 对象存储服务商预设：决定 endpoint 域名模板与展示文案。
/// 全部走同一套 S3 兼容 API + SigV4 签名（S3Client 不感知服务商差异），
/// 新增服务商 = 加一个 case + 域名模板。
public enum StorageProvider: String, CaseIterable, Sendable {
    case tencentCOS = "tencent-cos"
    /// 预留：阿里云 OSS S3 兼容端点（未实测，暂不进设置页）
    case alibabaOSS = "alibaba-oss"
    /// 预留：Amazon S3（未实测，暂不进设置页）
    case amazonS3 = "amazon-s3"
    /// 预留：Google Cloud Storage HMAC 互操作（未实测，暂不进设置页）
    case googleGCS = "google-gcs"
    case custom = "custom"

    public var displayName: String {
        switch self {
        case .tencentCOS: return "腾讯云 COS"
        case .alibabaOSS: return "阿里云 OSS"
        case .amazonS3: return "Amazon S3"
        case .googleGCS: return "Google Cloud Storage"
        case .custom: return "自定义 S3 兼容"
        }
    }

    /// endpoint host 模板（不含 bucket 前缀、不含 scheme）；custom 返回 nil = 用户自填
    public func endpointHost(region: String) -> String? {
        switch self {
        case .tencentCOS: return "cos.\(region).myqcloud.com"
        case .alibabaOSS: return "oss-\(region).aliyuncs.com"
        case .amazonS3: return "s3.\(region).amazonaws.com"
        case .googleGCS: return "storage.googleapis.com"
        case .custom: return nil
        }
    }

    /// region 输入框占位提示
    public var regionHint: String {
        switch self {
        case .tencentCOS: return "如 ap-guangzhou"
        case .alibabaOSS: return "如 cn-hangzhou"
        case .amazonS3: return "如 us-east-1"
        case .googleGCS: return "如 auto"
        case .custom: return "SigV4 签名用的 region"
        }
    }

    /// 首期设置页可选集合；其余 case 为架构预留，验证后加入即可
    public static var selectable: [StorageProvider] { [.tencentCOS, .custom] }
}
