import Foundation

/// Parses the request-target's query string into ordered key/value pairs with
/// percent-decoding, matching `URL.searchParams` for the cases the server
/// consumes (prefix, delimiter, max-keys, list-type, continuation-token).
enum RequestQuery {
    /// Returns the first value for `key`, or nil.
    static func value(_ key: String, in target: String) -> String? {
        pairs(in: target).first(where: { $0.0 == key })?.1
    }

    /// Returns the raw (encoded) first value, matching how the reference reads
    /// `url.searchParams` for the list parameters.
    static func pairs(in target: String) -> [(String, String)] {
        guard let question = target.firstIndex(of: "?") else { return [] }
        let query = target[target.index(after: question)...]
        guard !query.isEmpty else { return [] }

        var result: [(String, String)] = []
        for rawPair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let separator = rawPair.firstIndex(of: "=")
            let rawKey = separator.map { rawPair[..<$0] } ?? rawPair[...]
            let rawValue = separator.map { rawPair[rawPair.index(after: $0)...] } ?? Substring()
            let key = decode(rawKey)
            let value = decode(rawValue)
            result.append((key, value))
        }
        return result
    }

    /// The path portion of the request target (everything before `?`).
    static func path(in target: String) -> String {
        if let question = target.firstIndex(of: "?") {
            return String(target[..<question])
        }
        return target
    }

    /// The host value derived from request headers, lowercased and with any
    /// trailing port stripped, matching `URL.hostname`.
    static func hostname(from headers: [String: String]) -> String? {
        guard let host = headerValue("host", in: headers) else { return nil }
        // IPv6 literals like [::1] keep the brackets; only strip a trailing
        // `:port` for plain hostnames/IPv4.
        if host.hasPrefix("[") {
            return host.lowercased()
        }
        if let colon = host.firstIndex(of: ":") {
            return String(host[..<colon]).lowercased()
        }
        return host.lowercased()
    }

    static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func decode(_ value: Substring) -> String {
        if let decoded = try? SigV4Canonicalization.percentDecode(value) {
            return decoded
        }
        return String(value)
    }
}
