import Foundation

/// Parses HTTP/1.1 requests. The connection reads a request's head first (`head(_:isComplete:)`), checks it, and only
/// then takes the body (`takeBody(upTo:)` for bytes that came with the head, then the connection's own reads), so an
/// unsigned request never makes the server hold its body. `append` parses whole requests, body in memory.
struct HTTPRequestParser: Sendable {
    /// Received bytes not consumed yet: a head in progress, or body bytes that came with the head
    private(set) var buffer = Data()
    let maximumBodyBytes: Int
    let maximumRequestLineBytes: Int
    let maximumHeaderBytes: Int
    /// The head `append` parsed while it waits for the body
    private var pending: HTTPRequestHead?

    init(
        maximumBodyBytes: Int,
        maximumRequestLineBytes: Int = 8 * 1024,
        maximumHeaderBytes: Int = 64 * 1024
    ) {
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumRequestLineBytes = maximumRequestLineBytes
        self.maximumHeaderBytes = maximumHeaderBytes
    }

    /// Returns true when the parsed request carried `Connection: close`,
    /// signaling the server to close after the response.
    private(set) var wantsClose = false

    /// Resets parser state for a new request on a keep-alive connection,
    /// preserving any pipelined bytes already buffered past the prior body.
    mutating func resetForNextRequest() {
        wantsClose = false
        pending = nil
    }

    /// Adds `data` and returns the request's head once it's complete. Bytes past the head stay buffered for
    /// `takeBody(upTo:)`.
    mutating func head(_ data: Data, isComplete: Bool = false) throws -> HTTPRequestHead? {
        buffer.append(data)

        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maximumHeaderBytes {
                throw HTTPTransportError.requestHeadersTooLarge
            }
            if isComplete {
                throw HTTPTransportError.badRequest("Premature end of request headers")
            }
            return nil
        }

        let headerEnd = headerRange.upperBound - buffer.startIndex
        guard headerEnd <= maximumHeaderBytes else {
            throw HTTPTransportError.requestHeadersTooLarge
        }

        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPTransportError.badRequest("Request headers are not valid UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPTransportError.badRequest("Missing request line")
        }
        guard requestLine.utf8.count <= maximumRequestLineBytes else {
            throw HTTPTransportError.requestHeadersTooLarge
        }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              !requestParts[0].isEmpty,
              !requestParts[1].isEmpty,
              requestParts[2] == "HTTP/1.1"
        else {
            throw HTTPTransportError.badRequest("Malformed HTTP/1.1 request line")
        }

        var headers: [String: String] = [:]
        var contentLength: Int?
        var expectsContinue = false
        for line in lines {
            guard !line.isEmpty,
                  let colon = line.firstIndex(of: ":")
            else {
                throw HTTPTransportError.badRequest("Malformed request header")
            }

            let rawName = line[..<colon]
            guard !rawName.isEmpty, rawName.allSatisfy(Self.isHeaderNameCharacter) else {
                throw HTTPTransportError.badRequest("Malformed request header name")
            }

            let name = rawName.lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if name == "content-length" {
                guard contentLength == nil,
                      !value.isEmpty,
                      value.allSatisfy(\.isNumber),
                      let parsed = Int(value)
                else {
                    throw HTTPTransportError.badRequest("Invalid or ambiguous Content-Length")
                }
                contentLength = parsed
            } else if name == "transfer-encoding" {
                throw HTTPTransportError.unsupportedTransferEncoding
            } else if name == "connection" {
                if value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .contains(where: { $0.caseInsensitiveCompare("close") == .orderedSame })
                {
                    wantsClose = true
                }
            } else if name == "expect" {
                expectsContinue = value.caseInsensitiveCompare("100-continue") == .orderedSame
            }

            if let existing = headers[name] {
                headers[name] = "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }

        buffer.removeSubrange(..<headerRange.upperBound)
        buffer = Data(buffer)
        return HTTPRequestHead(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            headers: headers,
            contentLength: contentLength ?? 0,
            wantsClose: wantsClose,
            expectsContinue: expectsContinue
        )
    }

    /// Takes up to `count` buffered body bytes; what's left past them is the next request
    mutating func takeBody(upTo count: Int) -> Data {
        let taken = min(count, buffer.count)
        guard taken > 0 else { return Data() }
        let body = Data(buffer.prefix(taken))
        buffer = Data(buffer.dropFirst(taken))
        return body
    }

    /// Keeps bytes that came past a body: the start of the next request
    mutating func push(_ data: Data) {
        buffer.append(data)
    }

    /// Parses a whole request, body in memory: the head, then `Content-Length` bytes. Enforces
    /// `maximumBodyBytes` from the head.
    mutating func append(_ data: Data, isComplete: Bool = false) throws -> HTTPRequest? {
        let head: HTTPRequestHead
        if let pending {
            buffer.append(data)
            head = pending
        } else {
            guard let parsed = try self.head(data, isComplete: isComplete) else { return nil }
            if maximumBodyBytes > 0, parsed.contentLength > maximumBodyBytes {
                throw HTTPTransportError.payloadTooLarge
            }
            head = parsed
        }
        guard buffer.count >= head.contentLength else {
            pending = head
            if isComplete {
                throw HTTPTransportError.badRequest("Premature end of request body")
            }
            return nil
        }
        pending = nil
        return HTTPRequest(head: head, body: takeBody(upTo: head.contentLength))
    }

    private static func isHeaderNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (
            character.isLetter
                || character.isNumber
                || "!#$%&'*+-.^_`|~".contains(character)
        )
    }
}
