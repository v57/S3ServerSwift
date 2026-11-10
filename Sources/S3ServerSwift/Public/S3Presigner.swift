import Foundation

/// Presigned URLs for a server: links that carry their SigV4 signature in the query, so whoever holds one can GET
/// or PUT that object until it expires without the keys
public struct S3Presigner: Sendable {
    /// `http://host:port`, what the links' clients dial
    public var endpoint: URL
    public var bucket: String
    public var accessKeyID: String
    public var secretAccessKey: String
    public var region: String

    public init(endpoint: URL, bucket: String, accessKeyID: String, secretAccessKey: String, region: String = "us-east-1") {
        self.endpoint = endpoint
        self.bucket = bucket
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
    }

    /// A link for `method` (GET, PUT, HEAD, DELETE) on `key`, valid for `expires` seconds from `date` (S3 allows up
    /// to 7 days, 604800)
    public func url(method: String, key: String, expires: Int = 604_800, date: Date = Date()) -> URL {
        let path = "/" + ([bucket] + key.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
            .map(SigV4Canonicalization.encodeRFC3986).joined(separator: "/")
        let timestamp = SigV4Dates.awsTimestamp(date)
        let day = String(timestamp.prefix(8))
        let scope = "\(day)/\(region)/s3/aws4_request"
        let query = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKeyID)/\(scope)"),
            ("X-Amz-Date", timestamp),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        .map { (SigV4Canonicalization.encodeRFC3986($0.0), SigV4Canonicalization.encodeRFC3986($0.1)) }
        .sorted { $0.0 < $1.0 }
        .map { "\($0.0)=\($0.1)" }
        .joined(separator: "&")
        let canonicalRequest = [
            method.uppercased(),
            (try? SigV4Canonicalization.canonicalURI(path)) ?? path,
            query,
            "host:\(host)\n",
            "host",
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            CryptoPrimitives.sha256Hex(canonicalRequest),
        ].joined(separator: "\n")
        let key = CryptoPrimitives.signingKey(secret: secretAccessKey, date: day, region: region, service: "s3")
        let signature = Hex.encode(CryptoPrimitives.hmacSHA256(key: key, string: stringToSign))
        let origin = endpoint.absoluteString.hasSuffix("/") ? String(endpoint.absoluteString.dropLast()) : endpoint.absoluteString
        return URL(string: "\(origin)\(path)?\(query)&X-Amz-Signature=\(signature)")!
    }

    /// The `Host` header a client sends: the port unless it's the scheme's own
    private var host: String {
        let name = endpoint.host ?? ""
        let bracketed = name.contains(":") ? "[\(name)]" : name
        guard let port = endpoint.port else { return bracketed }
        let defaultPort = endpoint.scheme == "https" ? 443 : 80
        return port == defaultPort ? bracketed : "\(bracketed):\(port)"
    }
}
