import CryptoKit
import Foundation

/// Where the bucket is. Any S3-compatible service works; requests use path-style addresses
/// (`https://endpoint/bucket/key`).
public struct S3Configuration: Equatable, Sendable {
    public var endpoint: URL
    public var region: String
    public var bucket: String

    public init(endpoint: URL, region: String, bucket: String) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
    }
}

public struct S3Credentials: Equatable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

public struct S3Error: Error, CustomStringConvertible, Sendable {
    public let status: Int
    /// The service's error code, such as `NoSuchKey` or `AccessDenied`.
    public let code: String?
    public let message: String?

    public var isNotFound: Bool { status == 404 }

    public var description: String {
        var text = "the storage service answered \(status)"
        if let code { text += " \(code)" }
        if let message, !message.isEmpty { text += ": \(message)" }
        return text
    }
}

/// The few S3 requests the recorder and the viewer need, signed with AWS Signature Version 4.
/// Written with URLSession and CryptoKit, so the project needs no third-party code.
public struct S3Client: Sendable {
    public let configuration: S3Configuration
    private let credentials: S3Credentials
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(configuration: S3Configuration, credentials: S3Credentials, session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.credentials = credentials
        self.session = session
        self.now = now
    }

    // MARK: Requests

    public func putObject(key: String, data: Data, contentType: String = "application/octet-stream") async throws {
        _ = try await send("PUT", key: key, headers: ["Content-Type": contentType], body: data)
    }

    public func getObject(key: String) async throws -> Data {
        try await send("GET", key: key)
    }

    public func deleteObject(key: String) async throws {
        _ = try await send("DELETE", key: key)
    }

    /// Makes the bucket delete every object under `prefix` once it is `days` old. This
    /// replaces all lifecycle rules the bucket had.
    public func putLifecycle(expireAfterDays days: Int, prefix: String) async throws {
        let xml = """
        <LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
        <Rule><ID>reolinkviewer-retention</ID><Filter><Prefix>\(prefix)</Prefix></Filter>\
        <Status>Enabled</Status><Expiration><Days>\(days)</Days></Expiration></Rule>\
        </LifecycleConfiguration>
        """
        let body = Data(xml.utf8)
        let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
        _ = try await send("PUT", key: nil, query: "lifecycle=", headers: ["Content-MD5": md5, "Content-Type": "application/xml"], body: body)
    }

    private func send(_ method: String, key: String?, query: String? = nil, headers: [String: String] = [:],
                      body: Data = Data()) async throws -> Data {
        var path = "/" + configuration.bucket
        if let key { path += "/" + key }
        let request = Self.signedRequest(method: method, endpoint: configuration.endpoint, path: path, query: query,
                                         headers: headers, body: body, region: configuration.region,
                                         credentials: credentials, date: now())
        let (data, response): (Data, URLResponse)
        if method == "PUT" {
            (data, response) = try await session.upload(for: request, from: body)
        } else {
            (data, response) = try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(decoding: data.prefix(2000), as: UTF8.self)
            throw S3Error(status: status, code: Self.element("Code", in: text), message: Self.element("Message", in: text))
        }
        return data
    }

    private static func element(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    // MARK: Signature Version 4

    /// Builds a signed request. `path` is the unencoded absolute path; `query` is already in
    /// canonical form (`name=value`, sorted, percent-encoded).
    static func signedRequest(method: String, endpoint: URL, path: String, query: String?, headers: [String: String],
                              body: Data, region: String, credentials: S3Credentials, date: Date) -> URLRequest {
        let stamp = DateFormatter()
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = stamp.string(from: date)
        let day = String(amzDate.prefix(8))

        var host = endpoint.host ?? ""
        if let port = endpoint.port, port != (endpoint.scheme == "http" ? 80 : 443) { host += ":\(port)" }
        let canonicalPath = (endpoint.path == "/" ? "" : endpoint.path) + path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }.joined(separator: "/")
        let payloadHash = hex(SHA256.hash(data: body))

        var signed = headers
        signed["Host"] = host
        signed["x-amz-content-sha256"] = payloadHash
        signed["x-amz-date"] = amzDate
        let sorted = signed.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }.sorted { $0.0 < $1.0 }
        let canonicalHeaders = sorted.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = sorted.map(\.0).joined(separator: ";")
        let canonicalRequest = [method, canonicalPath, query ?? "", canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")

        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")
        var key = hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), day)
        for part in [region, "s3", "aws4_request"] { key = hmac(key, part) }
        let signature = hex(hmac(key, stringToSign))

        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        components.percentEncodedPath = canonicalPath
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url ?? endpoint)
        request.httpMethod = method
        for (name, value) in signed where name != "Host" { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return request
    }

    /// Percent-encodes everything but the unreserved characters, as the signature demands.
    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
