import CryptoKit
import Foundation

/// 备份目标：任何兼容 S3 API 的对象存储（AWS S3、Cloudflare R2、MinIO、阿里云 OSS、腾讯云 COS 等）。
public struct S3Configuration: Codable, Sendable, Equatable {
    /// 例如 `https://s3.us-east-1.amazonaws.com`、`https://<account>.r2.cloudflarestorage.com`、`http://127.0.0.1:9000`。
    public var endpoint: String
    public var region: String
    public var bucket: String
    /// 桶内的前缀目录，例如 `LiteMD`。
    public var prefix: String
    /// 路径风格（`endpoint/bucket/key`）。MinIO、R2 通常需要开启。
    public var usesPathStyle: Bool
    public var accessKeyID: String

    public init(endpoint: String, region: String, bucket: String, prefix: String = "LiteMD", usesPathStyle: Bool = false, accessKeyID: String) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.usesPathStyle = usesPathStyle
        self.accessKeyID = accessKeyID
    }

    public var isComplete: Bool {
        ![endpoint, region, bucket, accessKeyID].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 规范化后的前缀：无首尾斜杠，非空时以 `/` 结尾。
    public var normalizedPrefix: String {
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : trimmed + "/"
    }

    /// 生成请求地址。`key` 为对象键（未编码）；`query` 为未编码的查询参数。
    func url(key: String?, query: [(String, String)] = []) throws(S3Error) -> URL {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            throw S3Error.invalidConfiguration("endpoint")
        }
        // 只允许本机调试使用明文 HTTP，其余必须 HTTPS。
        if scheme == "http", !["localhost", "127.0.0.1", "::1"].contains(host) {
            throw S3Error.invalidConfiguration("insecureEndpoint")
        }
        guard !bucket.isEmpty else { throw S3Error.invalidConfiguration("bucket") }

        let encodedKey = key.map { SigV4Signer.encode($0, keepSlash: true) } ?? ""
        if usesPathStyle {
            components.percentEncodedPath = "/" + SigV4Signer.encode(bucket, keepSlash: false) + (key == nil ? "" : "/" + encodedKey)
        } else {
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = "/" + encodedKey
        }
        if query.isEmpty {
            components.percentEncodedQuery = nil
        } else {
            components.percentEncodedQuery = query
                .map { "\(SigV4Signer.encode($0.0, keepSlash: false))=\(SigV4Signer.encode($0.1, keepSlash: false))" }
                .joined(separator: "&")
        }
        guard let url = components.url else { throw S3Error.invalidConfiguration("endpoint") }
        return url
    }
}

public struct S3Object: Equatable, Sendable {
    public var key: String
    /// 去掉引号的 ETag。单块上传且未使用 KMS 加密时等于内容的 MD5。
    public var eTag: String
    public var size: Int64

    public init(key: String, eTag: String, size: Int64) {
        self.key = key
        self.eTag = eTag
        self.size = size
    }
}

public enum S3Error: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case http(status: Int, code: String?, message: String?)
    case transport(String)
    case invalidResponse

    /// 可以重试的错误：网络、限流、服务端错误。
    var isTransient: Bool {
        switch self {
        case .transport: true
        case .http(let status, _, _): status == 429 || status >= 500
        default: false
        }
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws(S3Error) -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws(S3Error) -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
            return (data, http)
        } catch let error as S3Error {
            throw error
        } catch {
            throw S3Error.transport(error.localizedDescription)
        }
    }
}

/// 最小 S3 客户端：列举、上传、删除。所有请求使用 SigV4 签名。
public struct S3Client: Sendable {
    public let configuration: S3Configuration
    private let signer: SigV4Signer
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(configuration: S3Configuration, secretAccessKey: String, transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration
        self.signer = SigV4Signer(
            credentials: S3Credentials(accessKeyID: configuration.accessKeyID, secretAccessKey: secretAccessKey),
            region: configuration.region
        )
        self.transport = transport
        self.now = now
    }

    /// 连接测试：列举前缀下最多 1 个对象，验证地址、凭据与权限。
    public func checkAccess() async throws(S3Error) {
        _ = try await listPage(prefix: configuration.normalizedPrefix, continuationToken: nil, maxKeys: 1)
    }

    public func listObjects(prefix: String) async throws(S3Error) -> [S3Object] {
        var objects: [S3Object] = []
        var token: String?
        repeat {
            let page = try await listPage(prefix: prefix, continuationToken: token, maxKeys: 1000)
            objects.append(contentsOf: page.objects)
            token = page.nextToken
        } while token != nil
        return objects
    }

    @discardableResult
    public func putObject(key: String, data: Data, contentType: String) async throws(S3Error) -> String {
        var request = URLRequest(url: try configuration.url(key: key))
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Data(Insecure.MD5.hash(data: data)).base64EncodedString(), forHTTPHeaderField: "Content-MD5")
        let (_, response) = try await perform(request, payloadHash: SigV4Signer.hex(SHA256.hash(data: data)))
        return (response.value(forHTTPHeaderField: "ETag") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    public func getObject(key: String) async throws(S3Error) -> Data {
        var request = URLRequest(url: try configuration.url(key: key))
        request.httpMethod = "GET"
        return try await perform(request, payloadHash: SigV4Signer.emptyPayloadHash).0
    }

    /// 列出前缀下一层的“目录”（CommonPrefixes），例如各个 Workspace 的备份目录。
    public func listFolders(prefix: String) async throws(S3Error) -> [String] {
        var folders: [String] = []
        var token: String?
        repeat {
            var query = [("delimiter", "/"), ("list-type", "2"), ("max-keys", "1000"), ("prefix", prefix)]
            if let token { query.append(("continuation-token", token)) }
            var request = URLRequest(url: try configuration.url(key: nil, query: query))
            request.httpMethod = "GET"
            let (data, _) = try await perform(request, payloadHash: SigV4Signer.emptyPayloadHash)
            let page = try ListBucketParser.parse(data)
            folders.append(contentsOf: page.commonPrefixes)
            token = page.nextToken
        } while token != nil
        return folders
    }

    public func deleteObject(key: String) async throws(S3Error) {
        var request = URLRequest(url: try configuration.url(key: key))
        request.httpMethod = "DELETE"
        _ = try await perform(request, payloadHash: SigV4Signer.emptyPayloadHash)
    }

    private func listPage(prefix: String, continuationToken: String?, maxKeys: Int) async throws(S3Error) -> (objects: [S3Object], nextToken: String?) {
        var query = [("list-type", "2"), ("max-keys", String(maxKeys)), ("prefix", prefix)]
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        var request = URLRequest(url: try configuration.url(key: nil, query: query))
        request.httpMethod = "GET"
        let (data, _) = try await perform(request, payloadHash: SigV4Signer.emptyPayloadHash)
        let page = try ListBucketParser.parse(data)
        return (page.objects, page.nextToken)
    }

    /// 发送请求；网络错误、限流与服务端错误最多重试 3 次（指数退避）。
    private func perform(_ original: URLRequest, payloadHash: String) async throws(S3Error) -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            var request = original
            signer.sign(&request, payloadHash: payloadHash, date: now())
            do throws(S3Error) {
                let (data, response) = try await transport.send(request)
                guard (200..<300).contains(response.statusCode) else {
                    let error = ErrorResponseParser.parse(data)
                    throw S3Error.http(status: response.statusCode, code: error.code, message: error.message)
                }
                return (data, response)
            } catch where error.isTransient && attempt < 3 {
                attempt += 1
                try? await Task.sleep(for: .milliseconds(300 * (1 << attempt)))
            }
        }
    }
}

// MARK: - XML

private final class ListBucketParser: NSObject, XMLParserDelegate {
    private var objects: [S3Object] = []
    private var commonPrefixes: [String] = []
    private var nextToken: String?
    private var isTruncated = false
    private var isInCommonPrefixes = false
    private var text = ""
    private var key = ""
    private var eTag = ""
    private var size: Int64 = 0

    static func parse(_ data: Data) throws(S3Error) -> (objects: [S3Object], commonPrefixes: [String], nextToken: String?) {
        let delegate = ListBucketParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw S3Error.invalidResponse }
        return (delegate.objects, delegate.commonPrefixes, delegate.isTruncated ? delegate.nextToken : nil)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if elementName == "Contents" {
            key = ""
            eTag = ""
            size = 0
        }
        if elementName == "CommonPrefixes" { isInCommonPrefixes = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "Key": key = text
        case "ETag": eTag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        case "Size": size = Int64(text) ?? 0
        case "Prefix" where isInCommonPrefixes: commonPrefixes.append(text)
        case "CommonPrefixes": isInCommonPrefixes = false
        case "Contents": objects.append(S3Object(key: key, eTag: eTag, size: size))
        case "IsTruncated": isTruncated = text == "true"
        case "NextContinuationToken": nextToken = text
        default: break
        }
    }
}

private final class ErrorResponseParser: NSObject, XMLParserDelegate {
    private var code: String?
    private var message: String?
    private var text = ""

    static func parse(_ data: Data) -> (code: String?, message: String?) {
        let delegate = ErrorResponseParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return (delegate.code, delegate.message)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "Code" { code = text }
        if elementName == "Message" { message = text }
    }
}
