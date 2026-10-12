import Foundation

enum SigV4ParsingError: Error, Equatable {
    case invalidCredentialScope
    case invalidCredentialTerminator
    case invalidTimestamp
}

struct CredentialScope: Sendable, Equatable {
    var accessKeyID: String
    var date: String
    var region: String
    var service: String

    var scope: String {
        "\(date)/\(region)/\(service)/aws4_request"
    }

    static func parse(_ value: String) throws -> CredentialScope {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 else {
            throw SigV4ParsingError.invalidCredentialScope
        }
        guard parts[4] == "aws4_request" else {
            throw SigV4ParsingError.invalidCredentialTerminator
        }
        return CredentialScope(
            accessKeyID: parts[0],
            date: parts[1],
            region: parts[2],
            service: parts[3]
        )
    }
}

enum SigV4Dates {
    static func parseAWSTimestamp(_ value: String) throws -> Date {
        guard value.count == 16, let date = awsTimestampFormatter.date(from: value) else {
            throw SigV4ParsingError.invalidTimestamp
        }
        return date
    }

    static func awsTimestamp(_ date: Date) -> String {
        awsTimestampFormatter.string(from: date)
    }

    static func iso8601ListDate(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    static func httpLastModified(_ date: Date) -> String {
        httpDateFormatter.string(from: date)
    }

    private static let awsTimestampFormatter = formatter("yyyyMMdd'T'HHmmss'Z'")
    private static let iso8601Formatter = formatter("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
    private static let httpDateFormatter = formatter("EEE, dd MMM yyyy HH:mm:ss 'GMT'")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
}
