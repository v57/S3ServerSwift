import Foundation

struct HTTPRequest: Sendable {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    var fileBody: HTTPFileBody? = nil

    var contentLength: UInt64 {
        fileBody?.length ?? UInt64(body.count)
    }
}

struct HTTPFileBody: Sendable {
    var url: URL
    var length: UInt64
}

enum HTTPTransportError: Error, Equatable {
    case badRequest(String)
    case payloadTooLarge
    case requestHeadersTooLarge
    case unsupportedTransferEncoding

    /// Transport-level error framing. Body-size violations surface the S3 XML
    /// `EntityTooLarge` document so clients observe reference-compatible S3
    /// errors even though the limit is enforced before authentication.
    var response: HTTPResponse {
        switch self {
        case .payloadTooLarge:
            return S3Responses.xmlError(.entityTooLarge)
        case let .badRequest(detail):
            return HTTPResponse(
                status: 400,
                headers: ["content-type": "text/plain; charset=utf-8"],
                body: Data(detail.utf8)
            )
        case .requestHeadersTooLarge:
            return HTTPResponse(
                status: 431,
                headers: ["content-type": "text/plain; charset=utf-8"],
                body: Data("Request Header Fields Too Large".utf8)
            )
        case .unsupportedTransferEncoding:
            return HTTPResponse(
                status: 501,
                headers: ["content-type": "text/plain; charset=utf-8"],
                body: Data("Transfer-Encoding is not supported".utf8)
            )
        }
    }
}
