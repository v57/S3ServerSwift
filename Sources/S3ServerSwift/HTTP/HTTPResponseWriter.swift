import Foundation

enum HTTPResponseWriter {
    static func serialize(_ response: HTTPResponse, suppressBody: Bool = false) -> Data {
        var output = serializeHead(response)
        if !suppressBody, response.fileBody == nil {
            output.append(response.body)
        }
        return output
    }

    static func serializeHead(_ response: HTTPResponse, keepAlive: Bool = false) -> Data {
        var headers = response.headers
        // Preserve an explicit content-length (HEAD responses carry the object
        // size with no body); otherwise derive it from the body/file.
        if headers["content-length"] == nil {
            headers["content-length"] = String(response.contentLength)
        }
        headers["connection"] = keepAlive ? "keep-alive" : "close"

        var output = Data("HTTP/1.1 \(response.status) \(reason(for: response.status))\r\n".utf8)
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            output.append(Data("\(name): \(value)\r\n".utf8))
        }
        output.append(Data("\r\n".utf8))
        return output
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        default: "Unknown"
        }
    }
}
