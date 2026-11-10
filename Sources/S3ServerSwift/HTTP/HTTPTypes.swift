import Foundation

/// A request's line and headers, all the server knows before it decides whether to read the body
struct HTTPRequestHead: Sendable {
    var method: String
    var target: String
    /// Lowercased names; repeated headers joined with ", "
    var headers: [String: String]
    var contentLength: Int = 0
    /// `Connection: close`
    var wantsClose = false
    /// `Expect: 100-continue`: the client waits for an interim answer before it sends the body
    var expectsContinue = false
}

struct HTTPRequest: Sendable {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data

    init(method: String, target: String, headers: [String: String], body: Data) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    init(head: HTTPRequestHead, body: Data) {
        self.init(method: head.method, target: head.target, headers: head.headers, body: body)
    }

    var head: HTTPRequestHead {
        HTTPRequestHead(method: method, target: target, headers: headers, contentLength: body.count)
    }
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

/// A file, or `length` bytes of it from `offset` (a range)
struct HTTPFileBody: Sendable {
    var url: URL
    var offset: UInt64 = 0
    var length: UInt64
}

enum HTTPTransportError: Error, Equatable {
    case badRequest(String)
    case payloadTooLarge
    case requestHeadersTooLarge
    case unsupportedTransferEncoding

    /// Transport-level error framing. Body-size violations surface the S3 XML
    /// `EntityTooLarge` document so clients observe reference-compatible S3
    /// errors.
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
