import Foundation
import Testing
@testable import S3ServerSwift

@Test func parserAcceptsFragmentedCaseInsensitiveHeadersAndBinaryBody() throws {
    var parser = HTTPRequestParser(maximumBodyBytes: 1024)
    #expect(try parser.append(Data("PUT /bucket/key HTTP/1.1\r\nHo".utf8)) == nil)
    #expect(try parser.append(Data("St: localhost\r\nContent-Length: 3\r\n\r\n".utf8)) == nil)

    let parsedRequest = try parser.append(Data([0x00, 0x7f, 0xff]))
    let request = try #require(parsedRequest)
    #expect(request.method == "PUT")
    #expect(request.target == "/bucket/key")
    #expect(request.headers["host"] == "localhost")
    #expect(request.body == Data([0x00, 0x7f, 0xff]))
}

@Test func parserAcceptsAnEmptyBody() throws {
    var parser = HTTPRequestParser(maximumBodyBytes: 0)
    let parsedRequest = try parser.append(
        Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    )
    let request = try #require(parsedRequest)
    #expect(request.body.isEmpty)
}

@Test(
    arguments: [
        "Content-Length: -1",
        "Content-Length: nope",
        "Content-Length: 1\r\nContent-Length: 1",
    ]
)
func parserRejectsInvalidOrAmbiguousLengths(_ header: String) {
    var parser = HTTPRequestParser(maximumBodyBytes: 1024)
    #expect(throws: HTTPTransportError.badRequest("Invalid or ambiguous Content-Length")) {
        try parser.append(Data("PUT / HTTP/1.1\r\n\(header)\r\n\r\n".utf8))
    }
}

@Test func parserRejectsDeclaredAndReceivedOversizedBodies() {
    var declared = HTTPRequestParser(maximumBodyBytes: 2)
    #expect(throws: HTTPTransportError.payloadTooLarge) {
        try declared.append(Data("PUT / HTTP/1.1\r\nContent-Length: 3\r\n\r\n".utf8))
    }

    var received = HTTPRequestParser(maximumBodyBytes: 2)
    #expect(throws: HTTPTransportError.payloadTooLarge) {
        try received.append(Data("PUT / HTTP/1.1\r\nContent-Length: 2\r\n\r\nabc".utf8))
    }
}

@Test func parserRejectsOversizedHeadersPrematureEOFAndChunking() {
    var headers = HTTPRequestParser(
        maximumBodyBytes: 0,
        maximumRequestLineBytes: 8,
        maximumHeaderBytes: 32
    )
    #expect(throws: HTTPTransportError.requestHeadersTooLarge) {
        try headers.append(Data("GET /a-long-target HTTP/1.1\r\n\r\n".utf8))
    }

    var eof = HTTPRequestParser(maximumBodyBytes: 0)
    #expect(throws: HTTPTransportError.badRequest("Premature end of request body")) {
        try eof.append(
            Data("PUT / HTTP/1.1\r\nContent-Length: 2\r\n\r\na".utf8),
            isComplete: true
        )
    }

    var chunked = HTTPRequestParser(maximumBodyBytes: 0)
    #expect(throws: HTTPTransportError.unsupportedTransferEncoding) {
        try chunked.append(
            Data("PUT / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        )
    }
}

@Test func responseWriterUsesExactFramingAndSuppressesHeadBody() {
    let response = HTTPResponse(
        status: 200,
        headers: ["content-type": "application/octet-stream"],
        body: Data([0x00, 0xff])
    )
    let expectedHead = "HTTP/1.1 200 OK\r\n"
        + "connection: close\r\n"
        + "content-length: 2\r\n"
        + "content-type: application/octet-stream\r\n"
        + "\r\n"

    var expected = Data(expectedHead.utf8)
    expected.append(Data([0x00, 0xff]))
    #expect(HTTPResponseWriter.serialize(response) == expected)
    #expect(HTTPResponseWriter.serialize(response, suppressBody: true) == Data(expectedHead.utf8))
}

@Test func parserTracksConnectionCloseHeader() throws {
    var keepAlive = HTTPRequestParser(maximumBodyBytes: 0)
    let keepAliveRequest = try #require(try keepAlive.append(
        Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    ))
    #expect(keepAliveRequest != nil)
    #expect(!keepAlive.wantsClose)

    var close = HTTPRequestParser(maximumBodyBytes: 0)
    _ = try close.append(
        Data("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
    )
    #expect(close.wantsClose)
}

@Test func parserKeepsPipelinedNextRequestAfterConsumingBody() throws {
    var parser = HTTPRequestParser(maximumBodyBytes: 1024)
    guard let first = try parser.append(
        Data(("PUT /a HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabc"
            + "GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n").utf8)
    ) else {
        Issue.record("Expected first request")
        return
    }
    #expect(first.method == "PUT")
    #expect(first.body == Data("abc".utf8))
    // The buffered GET remains for the next parse cycle.
    guard let second = try parser.append(Data()) else {
        Issue.record("Expected pipelined second request")
        return
    }
    #expect(second.method == "GET")
    #expect(second.target == "/b")
}

@Test func responseWriterKeepAliveHeaderIsExact() {
    let response = HTTPResponse(status: 200, body: Data())
    let serialized = HTTPResponseWriter.serializeHead(response, keepAlive: true)
    let text = String(data: serialized, encoding: .utf8) ?? ""
    #expect(text.contains("connection: keep-alive\r\n"))
    #expect(!text.contains("connection: close\r\n"))
}
