import Foundation

/// Configuration for the reusable S3-compatible server.
public struct S3ServerOptions: Sendable {
    public var host: String
    public var port: UInt16
    public var path: String?
    public var bucketPaths: [String: String]
    public var key: String
    public var secret: String
    public var sessionToken: String?
    public var maximumBodyBytes: Int
    public var maximumTimeSkewSeconds: Int

    public init(
        host: String = "0.0.0.0",
        port: UInt16 = 9000,
        path: String? = nil,
        bucketPaths: [String: String] = [:],
        key: String,
        secret: String,
        sessionToken: String? = nil,
        maximumBodyBytes: Int = 0,
        maximumTimeSkewSeconds: Int = 0,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) throws {
        var normalizedBucketPaths: [String: String] = [:]
        for (bucket, bucketPath) in bucketPaths {
            guard !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw S3ServerOptionsError.bucketNameRequired
            }
            guard !bucket.contains("/"), !bucket.contains("\\") else {
                throw S3ServerOptionsError.invalidBucket
            }
            guard !bucketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw S3ServerOptionsError.bucketPathRequired(bucket)
            }
            normalizedBucketPaths[bucket] = try Self.normalizePath(
                bucketPath,
                environment: environment,
                workingDirectory: workingDirectory
            )
        }

        self.host = host
        self.port = port
        self.path = try path.map {
            try Self.normalizePath($0, environment: environment, workingDirectory: workingDirectory)
        }
        self.bucketPaths = normalizedBucketPaths
        self.key = key
        self.secret = secret
        self.sessionToken = sessionToken
        self.maximumBodyBytes = max(0, maximumBodyBytes)
        self.maximumTimeSkewSeconds = max(0, maximumTimeSkewSeconds)
    }

    static func normalizePath(
        _ value: String,
        environment: [String: String],
        workingDirectory: String
    ) throws -> String {
        let expanded: String
        if value == "~" || value.hasPrefix("~/") {
            guard let home = environment["HOME"], !home.isEmpty else {
                throw S3ServerOptionsError.homeRequired
            }
            expanded = value == "~"
                ? home
                : URL(fileURLWithPath: home).appendingPathComponent(String(value.dropFirst(2))).path
        } else {
            expanded = value
        }

        let absolute = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: workingDirectory).appendingPathComponent(expanded)
        return absolute.standardizedFileURL.path
    }
}

public enum S3ServerOptionsError: Error, Equatable, CustomStringConvertible {
    case bucketNameRequired
    case invalidBucket
    case bucketPathRequired(String)
    case homeRequired

    public var description: String {
        switch self {
        case .bucketNameRequired:
            "bucket name is required"
        case .invalidBucket:
            "invalid bucket"
        case let .bucketPathRequired(bucket):
            "bucket path is required for \(bucket)"
        case .homeRequired:
            "HOME is required to expand ~ paths"
        }
    }
}
