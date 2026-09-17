import Foundation

/// 常见 S3 兼容服务的预设：决定默认地址、区域与寻址方式。
public enum S3Provider: String, CaseIterable, Codable, Sendable {
    case aws
    case cloudflareR2
    case minio
    /// 阿里云 OSS、腾讯云 COS、Backblaze B2、Wasabi 等。
    case other

    public var displayName: String {
        switch self {
        case .aws: "Amazon S3"
        case .cloudflareR2: "Cloudflare R2"
        case .minio: "MinIO"
        case .other: "Other S3-Compatible Service"
        }
    }

    /// AWS 的地址由区域推导，其余服务需要填写。
    public var requiresEndpoint: Bool { self != .aws }

    public var defaultRegion: String {
        switch self {
        case .aws, .minio: "us-east-1"
        case .cloudflareR2: "auto"
        case .other: ""
        }
    }

    public var endpointPlaceholder: String {
        switch self {
        case .aws: "https://s3.us-east-1.amazonaws.com"
        case .cloudflareR2: "https://<account-id>.r2.cloudflarestorage.com"
        case .minio: "http://127.0.0.1:9000"
        case .other: "https://s3.example.com"
        }
    }

    public var regionPlaceholder: String {
        switch self {
        case .aws: "us-east-1"
        case .cloudflareR2: "auto"
        case .minio: "us-east-1"
        case .other: "us-east-1"
        }
    }

    /// 生成请求配置。AWS 桶名含 `.` 时使用路径风格，避免 HTTPS 证书与子域名不匹配。
    public func configuration(
        endpoint: String,
        region: String,
        bucket: String,
        prefix: String,
        usesPathStyle: Bool,
        accessKeyID: String
    ) -> S3Configuration {
        let region = region.trimmingCharacters(in: .whitespaces)
        let bucket = bucket.trimmingCharacters(in: .whitespaces)
        let accessKeyID = accessKeyID.trimmingCharacters(in: .whitespaces)
        switch self {
        case .aws:
            let resolvedRegion = region.isEmpty ? defaultRegion : region
            return S3Configuration(
                endpoint: "https://s3.\(resolvedRegion).amazonaws.com",
                region: resolvedRegion,
                bucket: bucket,
                prefix: prefix,
                usesPathStyle: bucket.contains("."),
                accessKeyID: accessKeyID
            )
        case .cloudflareR2, .minio:
            return S3Configuration(
                endpoint: endpoint.trimmingCharacters(in: .whitespaces),
                region: region.isEmpty ? defaultRegion : region,
                bucket: bucket,
                prefix: prefix,
                usesPathStyle: true,
                accessKeyID: accessKeyID
            )
        case .other:
            return S3Configuration(
                endpoint: endpoint.trimmingCharacters(in: .whitespaces),
                region: region,
                bucket: bucket,
                prefix: prefix,
                usesPathStyle: usesPathStyle,
                accessKeyID: accessKeyID
            )
        }
    }
}
