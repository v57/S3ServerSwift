import Foundation
import Security

/// Injectable command-line parser reproducing the reference `parseServerOptions`
/// so the executable and unit tests resolve identical options from argv and an
/// explicit environment map without mutating the test process environment.
public enum ServerOptionsParser {
    /// The result of parsing argv and environment: either a help request or a
    /// fully resolved option set.
    public enum Result: Sendable, Equatable {
        case help(usage: String)
        case options(ParsedServerOptions)
    }

    /// Parses argv and environment into either a help request or server options.
    ///
    /// `argv` excludes the program name (mirrors the reference
    /// `process.argv.slice(2)` default), and `environment` is the full
    /// `PORT`/`S3_*`/`AWS_*` variable map. Throws `ServerOptionsParseError` for
    /// malformed arguments so the entrypoint can print a clean diagnostic and
    /// exit nonzero without starting a listener.
    public static func parse(
        _ argv: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Result {
        var values: [String: String] = [:]
        var bucketPaths: [String] = []
        var positionals: [String] = []
        var help = false

        var index = 0
        while index < argv.count {
            let argument = argv[index]
            if argument == "--help" || argument == "-h" {
                help = true
                index += 1
                continue
            }
            if let (name, inlineValue) = flagValue(argument) {
                if let inlineValue {
                    if name == "bucket-path" {
                        bucketPaths.append(inlineValue)
                    } else {
                        values[name] = inlineValue
                    }
                    index += 1
                    continue
                }
                // Flag expecting a value: consume the next argument.
                index += 1
                guard index < argv.count else {
                    throw ServerOptionsParseError.missingValue(flag: argument)
                }
                if name == "bucket-path" {
                    bucketPaths.append(argv[index])
                } else {
                    values[name] = argv[index]
                }
                index += 1
                continue
            }
            // Unknown flag (starts with `--`) aborts, matching the reference
            // `parseArgs`, which throws "Unknown option". Bare positionals are
            // collected; the reference only consumes the first.
            if argument.hasPrefix("--") {
                throw ServerOptionsParseError.unknownOption(argument)
            }
            positionals.append(argument)
            index += 1
        }

        if help {
            return .help(usage: Self.helpText)
        }

        let parsedBucketPaths = try parseBucketPaths(bucketPaths)
        let explicitPath = values["path"] ?? positionals.first
        // The reference resolves `path` with `??`, then `S3ServerOptions` drops
        // a falsy (empty) path entirely. Mirror that: an empty resolved path
        // means no default root.
        let resolvedPath = explicitPath ?? environment["S3_DATA_DIR"] ?? "."
        let path = resolvedPath.isEmpty ? nil : resolvedPath

        let options = ParsedServerOptions(
            host: values["host"],
            port: parseInteger(values["port"] ?? environment["PORT"], fallback: 9000),
            path: path,
            bucketPaths: parsedBucketPaths,
            key: values["key"]
                ?? environment["S3_ACCESS_KEY_ID"]
                ?? environment["AWS_ACCESS_KEY_ID"]
                ?? generatedCredential(),
            secret: values["secret"]
                ?? environment["S3_SECRET_ACCESS_KEY"]
                ?? environment["AWS_SECRET_ACCESS_KEY"]
                ?? generatedCredential(),
            sessionToken: values["session-token"]
                ?? environment["S3_SESSION_TOKEN"]
                ?? environment["AWS_SESSION_TOKEN"],
            maxBodyBytes: parseInteger(values["max-body-bytes"] ?? environment["S3_MAX_BODY_BYTES"], fallback: 0),
            maxTimeSkewSeconds: parseInteger(
                values["max-time-skew-seconds"] ?? environment["S3_MAX_TIME_SKEW_SECONDS"],
                fallback: 0
            )
        )
        return .options(options)
    }

    public static let helpText = """
    Usage:
      bun server [path] [options]

    Options:
      --help, -h                  Show this help message
      --host <host>               Bind host (default 0.0.0.0)
      --port <port>               Bind port (default 9000)
      --path <path>               Default storage root
      --key <key>                 Access key ID
      --secret <secret>           Secret access key
      --session-token <token>     Session token
      --max-body-bytes <bytes>    Maximum upload size
      --max-time-skew-seconds <s> Maximum allowed time skew
      --bucket-path <bucket=path> Bucket-specific storage path; repeatable

    Examples:
      bun server ~/storage --port 9002
      bun server --path ~/storage --bucket-path photos=~/photos
    """
}

/// The fully resolved server options produced by `ServerOptionsParser`, before
/// `S3ServerOptions` path normalization/validation.
public struct ParsedServerOptions: Sendable, Equatable {
    public var host: String?
    public var port: Int
    public var path: String?
    public var bucketPaths: [String: String]
    public var key: String
    public var secret: String
    public var sessionToken: String?
    public var maxBodyBytes: Int
    public var maxTimeSkewSeconds: Int

    public init(
        host: String?,
        port: Int,
        path: String?,
        bucketPaths: [String: String],
        key: String,
        secret: String,
        sessionToken: String?,
        maxBodyBytes: Int,
        maxTimeSkewSeconds: Int
    ) {
        self.host = host
        self.port = port
        self.path = path
        self.bucketPaths = bucketPaths
        self.key = key
        self.secret = secret
        self.sessionToken = sessionToken
        self.maxBodyBytes = maxBodyBytes
        self.maxTimeSkewSeconds = maxTimeSkewSeconds
    }
}

extension ServerOptionsParser {
    /// The set of recognized value-flags and whether each consumes an inline
    /// `--name=value` form. The repeatable `--bucket-path` is handled inline.
    private static let valueFlags: Set<String> = [
        "host", "port", "path", "key", "secret",
        "session-token", "max-body-bytes", "max-time-skew-seconds", "bucket-path",
    ]

    /// Splits `--name=value` into `(name, value)`, or `--name` into `(name, nil)`.
    /// Returns nil for arguments that are not recognized value-flags.
    private static func flagValue(_ argument: String) -> (name: String, value: String?)? {
        guard argument.hasPrefix("--") else { return nil }
        let body = String(argument.dropFirst(2))
        if let equals = body.firstIndex(of: "=") {
            let name = String(body[..<equals])
            let value = String(body[body.index(after: equals)...])
            guard valueFlags.contains(name) else { return nil }
            return (name, value)
        }
        guard valueFlags.contains(body) else { return nil }
        return (body, nil)
    }

    /// Reference `parseBucketPaths`: `bucket=path` with separator neither at
    /// start nor end; otherwise throws a useful error.
    private static func parseBucketPaths(_ entries: [String]) throws -> [String: String] {
        var bucketPaths: [String: String] = [:]
        for entry in entries {
            guard let separatorIndex = entry.firstIndex(of: "="),
                  separatorIndex > entry.startIndex,
                  separatorIndex < entry.index(before: entry.endIndex)
            else {
                throw ServerOptionsParseError.invalidBucketPath(entry)
            }
            let bucket = String(entry[..<separatorIndex])
            let bucketPath = String(entry[entry.index(after: separatorIndex)...])
            bucketPaths[bucket] = bucketPath
        }
        return bucketPaths
    }

    /// Reference `parseInteger`: JavaScript `parseInt` prefix semantics with a
    /// fallback when parsing yields no integer.
    private static func parseInteger(_ value: String?, fallback: Int) -> Int {
        guard let value else { return fallback }
        guard let parsed = parseIntPrefix(value) else { return fallback }
        return parsed
    }

    /// JavaScript `parseInt(_, 10)`: optional leading whitespace, optional sign,
    /// then a run of decimal digits. Returns nil for `NaN`.
    private static func parseIntPrefix(_ value: String) -> Int? {
        let trimmed = value.drop(while: \.isWhitespace)
        let sign: String
        let digitsStart: Substring.Index
        if let first = trimmed.first, (first == "-" || first == "+") {
            sign = String(first)
            digitsStart = trimmed.index(after: trimmed.startIndex)
        } else {
            sign = ""
            digitsStart = trimmed.startIndex
        }
        let digits = trimmed[digitsStart...].prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(sign + digits)
    }

    /// Generates a 16-byte lowercase-hex credential, matching
    /// `randomBytes(16).toString('hex')`.
    private static func generatedCredential() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback that still yields 16 bytes of pseudo-random data.
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors raised by `ServerOptionsParser` for malformed arguments, matching the
/// reference abort conditions: unknown option, missing flag value, and
/// malformed bucket mapping.
public enum ServerOptionsParseError: Error, Equatable {
    case unknownOption(String)
    case missingValue(flag: String)
    case invalidBucketPath(String)

    public var diagnostic: String {
        switch self {
        case let .unknownOption(flag):
            "Unknown option '\(flag)'"
        case let .missingValue(flag):
            "Option '\(flag) <value>' argument missing"
        case let .invalidBucketPath(entry):
            "invalid bucket path \"\(entry)\". Use bucket=/some/path"
        }
    }
}

