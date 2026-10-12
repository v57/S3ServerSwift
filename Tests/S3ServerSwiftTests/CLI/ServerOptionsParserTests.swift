import Foundation
import Testing
@testable import S3ServerSwift

@Suite struct ServerOptionsParserTests {
    private func parse(
        _ argv: [String] = [],
        environment: [String: String] = [:]
    ) throws -> ServerOptionsParser.Result {
        try ServerOptionsParser.parse(argv, environment: environment)
    }

    private func options(
        _ argv: [String] = [],
        environment: [String: String] = [:]
    ) throws -> ParsedServerOptions {
        guard case let .options(parsed) = try parse(argv, environment: environment) else {
            throw TestError.notOptions
        }
        return parsed
    }

    private enum TestError: Error {
        case notOptions
    }

    // MARK: - Defaults

    @Test func defaultsWhenNothingSupplied() throws {
        let parsed = try options(environment: [:])
        #expect(parsed.host == nil)
        #expect(parsed.port == 9000)
        #expect(parsed.path == ".")
        #expect(parsed.bucketPaths.isEmpty)
        #expect(parsed.sessionToken == nil)
        #expect(parsed.maxBodyBytes == 0)
        #expect(parsed.maxTimeSkewSeconds == 0)
        // Credentials are generated 32-char lowercase hex.
        #expect(parsed.key.count == 32)
        #expect(parsed.secret.count == 32)
        #expect(parsed.key.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil)
        #expect(parsed.secret.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil)
        #expect(parsed.key != parsed.secret)
    }

    // MARK: - Argument parsing

    @Test func allLongFlagsParse() throws {
        let parsed = try options([
            "--host", "127.0.0.1",
            "--port", "8080",
            "--path", "/tmp/data",
            "--key", "access",
            "--secret", "secret123",
            "--session-token", "token123",
            "--max-body-bytes", "1024",
            "--max-time-skew-seconds", "60",
        ])
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.port == 8080)
        #expect(parsed.path == "/tmp/data")
        #expect(parsed.key == "access")
        #expect(parsed.secret == "secret123")
        #expect(parsed.sessionToken == "token123")
        #expect(parsed.maxBodyBytes == 1024)
        #expect(parsed.maxTimeSkewSeconds == 60)
    }

    @Test func inlineEqualsValuesParse() throws {
        let parsed = try options([
            "--host=0.0.0.0",
            "--port=9999",
            "--path=/tmp/x",
            "--bucket-path=photos=/tmp/photos",
        ])
        #expect(parsed.host == "0.0.0.0")
        #expect(parsed.port == 9999)
        #expect(parsed.path == "/tmp/x")
        #expect(parsed.bucketPaths == ["photos": "/tmp/photos"])
    }

    @Test func positionalPathIsUsed() throws {
        let parsed = try options(["/var/storage"])
        #expect(parsed.path == "/var/storage")
    }

    @Test func explicitPathWinsOverPositional() throws {
        let parsed = try options(["--path", "/explicit", "/positional"])
        #expect(parsed.path == "/explicit")
    }

    @Test func pathFlagWinsOverS3DataDirWhichWinsOverDot() throws {
        let flag = try options(["--path", "/flag"], environment: ["S3_DATA_DIR": "/env"])
        #expect(flag.path == "/flag")

        let env = try options([], environment: ["S3_DATA_DIR": "/env"])
        #expect(env.path == "/env")
    }

    @Test func emptyS3DataDirMeansNoDefaultRoot() throws {
        let parsed = try options([], environment: ["S3_DATA_DIR": ""])
        #expect(parsed.path == nil)
    }

    // MARK: - Precedence

    @Test func argumentWinsOverS3AndAWSEnvironment() throws {
        let parsed = try options(
            ["--key", "arg-key", "--secret", "arg-secret", "--port", "1111"],
            environment: [
                "S3_ACCESS_KEY_ID": "s3-key",
                "AWS_ACCESS_KEY_ID": "aws-key",
                "S3_SECRET_ACCESS_KEY": "s3-secret",
                "AWS_SECRET_ACCESS_KEY": "aws-secret",
                "PORT": "2222",
            ]
        )
        #expect(parsed.key == "arg-key")
        #expect(parsed.secret == "arg-secret")
        #expect(parsed.port == 1111)
    }

    @Test func s3EnvironmentWinsOverAWS() throws {
        let parsed = try options([], environment: [
            "S3_ACCESS_KEY_ID": "s3-key",
            "AWS_ACCESS_KEY_ID": "aws-key",
            "S3_SECRET_ACCESS_KEY": "s3-secret",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "S3_SESSION_TOKEN": "s3-token",
            "AWS_SESSION_TOKEN": "aws-token",
        ])
        #expect(parsed.key == "s3-key")
        #expect(parsed.secret == "s3-secret")
        #expect(parsed.sessionToken == "s3-token")
    }

    @Test func awsEnvironmentFallsBackWhenS3Absent() throws {
        let parsed = try options([], environment: [
            "AWS_ACCESS_KEY_ID": "aws-key",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "AWS_SESSION_TOKEN": "aws-token",
        ])
        #expect(parsed.key == "aws-key")
        #expect(parsed.secret == "aws-secret")
        #expect(parsed.sessionToken == "aws-token")
    }

    @Test func portAndLimitsReadFromEnvironment() throws {
        let parsed = try options([], environment: [
            "PORT": "7777",
            "S3_MAX_BODY_BYTES": "2048",
            "S3_MAX_TIME_SKEW_SECONDS": "30",
        ])
        #expect(parsed.port == 7777)
        #expect(parsed.maxBodyBytes == 2048)
        #expect(parsed.maxTimeSkewSeconds == 30)
    }

    // MARK: - Repeatable bucket paths

    @Test func bucketPathIsRepeatable() throws {
        let parsed = try options([
            "--bucket-path", "photos=/tmp/photos",
            "--bucket-path", "videos=/tmp/videos",
        ])
        #expect(parsed.bucketPaths == [
            "photos": "/tmp/photos",
            "videos": "/tmp/videos",
        ])
    }

    @Test func malformedBucketPathThrows() {
        #expect(throws: ServerOptionsParseError.invalidBucketPath("=nobucket")) {
            _ = try parse(["--bucket-path", "=nobucket"])
        }
        #expect(throws: ServerOptionsParseError.invalidBucketPath("nopath=")) {
            _ = try parse(["--bucket-path", "nopath="])
        }
        #expect(throws: ServerOptionsParseError.invalidBucketPath("noseparator")) {
            _ = try parse(["--bucket-path", "noseparator"])
        }
    }

    // MARK: - Errors

    @Test func unknownOptionThrows() {
        #expect(throws: ServerOptionsParseError.unknownOption("--nope")) {
            _ = try parse(["--nope"])
        }
    }

    @Test func missingFlagValueThrows() {
        #expect(throws: ServerOptionsParseError.missingValue(flag: "--port")) {
            _ = try parse(["--port"])
        }
    }

    @Test func extraPositionalIsIgnored() throws {
        // The reference only consumes the first positional; extra positionals
        // are tolerated.
        let parsed = try options(["/first", "/second"])
        #expect(parsed.path == "/first")
    }

    // MARK: - Integer parsing

    @Test func integerPrefixParsingMatchesJavaScriptParseInt() throws {
        // "9000abc" → 9000, invalid text → fallback 9000.
        let prefixed = try options(["--port", "9000abc"])
        #expect(prefixed.port == 9000)

        let invalid = try options(["--port", "not-a-number"])
        #expect(invalid.port == 9000)

        let signed = try options(["--port", "-5"])
        #expect(signed.port == -5)
    }

    @Test func negativeLimitsFlowThroughToNormalization() throws {
        // Parser produces the raw negative; S3ServerOptions clamps to zero.
        let parsed = try options(["--max-body-bytes", "-10"])
        #expect(parsed.maxBodyBytes == -10)
        let serverOptions = try S3ServerOptions(
            path: parsed.path,
            bucketPaths: parsed.bucketPaths,
            key: parsed.key,
            secret: parsed.secret,
            sessionToken: parsed.sessionToken,
            maximumBodyBytes: parsed.maxBodyBytes,
            maximumTimeSkewSeconds: parsed.maxTimeSkewSeconds
        )
        #expect(serverOptions.maximumBodyBytes == 0)
    }

    // MARK: - Help

    @Test func helpFlagReturnsUsage() throws {
        let help = try parse(["--help"])
        guard case let .help(usage) = help else {
            Issue.record("Expected help result")
            return
        }
        #expect(usage.contains("Usage:"))
        #expect(usage.contains("--bucket-path"))
        #expect(usage.contains("--max-time-skew-seconds"))
    }

    @Test func shortHelpFlagReturnsUsage() throws {
        let help = try parse(["-h"])
        guard case .help = help else {
            Issue.record("Expected help result")
            return
        }
    }
}
