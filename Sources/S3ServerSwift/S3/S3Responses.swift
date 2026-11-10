import Foundation

/// Shared XML generation for S3 errors, mirroring the reference `s3Error` and
/// `xmlResponse` helpers so every operation produces identical XML framing.
enum S3Responses {
    static func xmlError(_ error: S3Error, requestId: String = UUID().uuidString) -> HTTPResponse {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error>
          <Code>\(Self.xmlEscape(error.code))</Code>
          <Message>\(Self.xmlEscape(error.message))</Message>
          <RequestId>\(requestId)</RequestId>
        </Error>
        """
        return HTTPResponse(
            status: error.status,
            headers: ["content-type": "application/xml; charset=utf-8"],
            body: Data(body.utf8)
        )
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

extension S3Error {
    static let accessDenied = S3Error(code: "AccessDenied", message: "Access Denied", status: 403)
    static func accessDenied(_ message: String) -> S3Error {
        S3Error(code: "AccessDenied", message: message, status: 403)
    }
    static let entityTooLarge = S3Error(code: "EntityTooLarge", message: "Payload too large", status: 413)
    static let methodNotAllowed = S3Error(code: "MethodNotAllowed", message: "Unsupported method", status: 405)
    static let noSuchKey = S3Error(code: "NoSuchKey", message: "Object not found", status: 404)
    static let noSuchBucketConfigured = S3Error(code: "NoSuchBucket", message: "Bucket not configured", status: 404)
    static let bucketNotSpecified = S3Error(code: "NoSuchBucket", message: "Bucket not specified", status: 404)
    static let keyRequired = S3Error(code: "InvalidRequest", message: "Key is required", status: 400)
    static let unsupportedListType = S3Error(code: "InvalidRequest", message: "Unsupported list type", status: 400)
    static func internalError(_ message: String) -> S3Error {
        S3Error(code: "InternalError", message: message, status: 500)
    }
    static func invalidURI(_ message: String) -> S3Error {
        S3Error(code: "InvalidURI", message: message, status: 400)
    }
}
