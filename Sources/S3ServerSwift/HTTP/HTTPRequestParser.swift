import Foundation

struct HTTPRequestParser: Sendable {
    private(set) var buffer = Data()
    let maximumBodyBytes: Int
    let maximumRequestLineBytes: Int
    let maximumHeaderBytes: Int

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
        // `buffer` holds only unconsumed bytes from here on; the connection
        // calls this after consuming a completed request's bytes.
    }

    mutating func append(_ data: Data, isComplete: Bool = false) throws -> HTTPRequest? {
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

        let headerEnd = headerRange.upperBound
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
            }

            if let existing = headers[name] {
                headers[name] = "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }

        let expectedBodyBytes = contentLength ?? 0
        if maximumBodyBytes > 0, expectedBodyBytes > maximumBodyBytes {
            throw HTTPTransportError.payloadTooLarge
        }

        let receivedBodyBytes = buffer.count - headerEnd
        if maximumBodyBytes > 0, receivedBodyBytes > maximumBodyBytes {
            throw HTTPTransportError.payloadTooLarge
        }
        guard receivedBodyBytes >= expectedBodyBytes else {
            if isComplete {
                throw HTTPTransportError.badRequest("Premature end of request body")
            }
            return nil
        }

        let bodyEnd = headerEnd + expectedBodyBytes
        let request = HTTPRequest(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            headers: headers,
            body: buffer[headerEnd..<bodyEnd]
        )
        // Drop the consumed request bytes; anything past the body is a
        // pipelined next request the connection will parse next.
        buffer.removeSubrange(..<bodyEnd)
        return request
    }

    private static func isHeaderNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (
            character.isLetter
                || character.isNumber
                || "!#$%&'*+-.^_`|~".contains(character)
        )
    }
}
