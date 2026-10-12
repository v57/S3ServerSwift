import Foundation

enum CanonicalizationError: Error, Equatable {
    case invalidPercentEncoding
    case invalidUTF8
    case emptySignedHeaders
    case missingHost
    case missingSignedHeader(String)
}

enum SigV4Canonicalization {
    private static let unreserved = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8
    )

    static func encodeRFC3986(_ value: String) -> String {
        var output = ""
        for byte in value.utf8 {
            if unreserved.contains(byte) {
                output.append(Character(UnicodeScalar(byte)))
            } else {
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }

    static func percentDecode(_ value: Substring, plusAsSpace: Bool = false) throws -> String {
        let bytes = Array(value.utf8)
        var decoded = [UInt8]()
        decoded.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            if bytes[index] == 0x25 {
                guard
                    index + 2 < bytes.count,
                    let high = hexNibble(bytes[index + 1]),
                    let low = hexNibble(bytes[index + 2])
                else {
                    throw CanonicalizationError.invalidPercentEncoding
                }
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(plusAsSpace && bytes[index] == 0x2B ? 0x20 : bytes[index])
                index += 1
            }
        }

        guard let result = String(bytes: decoded, encoding: .utf8) else {
            throw CanonicalizationError.invalidUTF8
        }
        return result
    }

    static func canonicalURI(_ pathname: String) throws -> String {
        guard !pathname.isEmpty else { return "/" }
        let encodedSegments = try pathname.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                try encodeRFC3986(percentDecode(segment))
            }
        let joined = encodedSegments.joined(separator: "/")
        return joined.hasPrefix("/") ? joined : "/\(joined)"
    }

    static func canonicalQuery(_ rawQuery: String?, excluding excludedKeys: Set<String> = []) throws -> String {
        guard let rawQuery, !rawQuery.isEmpty else { return "" }
        var pairs = [(key: String, value: String)]()

        for rawPair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let separator = rawPair.firstIndex(of: "=")
            let rawKey = separator.map { rawPair[..<$0] } ?? rawPair[...]
            let rawValue = separator.map { rawPair[rawPair.index(after: $0)...] } ?? Substring()
            let key = try percentDecode(rawKey, plusAsSpace: true)
            guard !excludedKeys.contains(key) else { continue }
            let value = try percentDecode(rawValue, plusAsSpace: true)
            pairs.append((encodeRFC3986(key), encodeRFC3986(value)))
        }

        pairs.sort {
            $0.key == $1.key ? $0.value < $1.value : $0.key < $1.key
        }
        return pairs.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    static func parseSignedHeaders(_ value: String) throws -> [String] {
        let headers = value.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !headers.isEmpty else {
            throw CanonicalizationError.emptySignedHeaders
        }
        guard headers.contains("host") else {
            throw CanonicalizationError.missingHost
        }
        return headers
    }

    static func canonicalHeaders(
        headers: [String: String],
        signedHeaders: [String],
        fallbackHost: String? = nil
    ) throws -> String {
        let normalizedHeaders = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        var output = ""
        for header in signedHeaders {
            let name = header.lowercased()
            let value = normalizedHeaders[name] ?? (name == "host" ? fallbackHost : nil)
            guard let value else {
                throw CanonicalizationError.missingSignedHeader(name)
            }
            output += "\(name):\(normalizeHeaderValue(value))\n"
        }
        return output
    }

    static func normalizeHeaderValue(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            byte - 48
        case 65...70:
            byte - 55
        case 97...102:
            byte - 87
        default:
            nil
        }
    }
}
