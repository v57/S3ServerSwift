import Foundation
import S3ServerSwift

/// Held globally so the C signal handlers can stop the server without
/// capturing context (Swift signal handlers must be context-free closures).
nonisolated(unsafe) private var activeServer: S3Server?

/// Serializes shutdown work off the signal handler so stop/exit happens once.
private let signalQueue = DispatchQueue(label: "S3ServerSwift.signals")

/// Retains the dispatch signal sources for the process lifetime.
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

@main
struct ServerCommand {
    static func main() {
        do {
            try run(
                arguments: CommandLine.arguments,
                environment: ProcessInfo.processInfo.environment
            )
        } catch let error as ServerOptionsParseError {
            FileHandle.standardError.write(Data("\(error.diagnostic)\n".utf8))
            exit(EXIT_FAILURE)
        } catch let error as S3ServerOptionsError {
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            exit(EXIT_FAILURE)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func run(arguments: [String], environment: [String: String]) throws {
        let argv = Array(arguments.dropFirst())
        let parsed = try ServerOptionsParser.parse(argv, environment: environment)

        switch parsed {
        case let .help(usage):
            FileHandle.standardOutput.write(Data("\(usage)\n".utf8))
            exit(EXIT_SUCCESS)
        case let .options(options):
            try startServer(options: options, environment: environment)
        }
    }

    static func startServer(options: ParsedServerOptions, environment: [String: String]) throws {
        let serverOptions = try S3ServerOptions(
            host: options.host ?? "0.0.0.0",
            port: numericCast(clampingPort(options.port)),
            path: options.path,
            bucketPaths: options.bucketPaths,
            key: options.key,
            secret: options.secret,
            sessionToken: options.sessionToken,
            maximumBodyBytes: options.maxBodyBytes,
            maximumTimeSkewSeconds: options.maxTimeSkewSeconds,
            environment: environment
        )

        let server = S3Server(options: serverOptions)
        activeServer = server
        installSignalHandlers()

        Task {
            do {
                try await server.start()
                await logStartup(options: options, server: server)
            } catch {
                FileHandle.standardError.write(Data("Failed to start server: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }

        // Keep the process alive until a signal handler stops the server.
        dispatchMain()
    }

    static func logStartup(options: ParsedServerOptions, server: S3Server) async {
        let port = await server.boundPort ?? UInt16(clampingPort(options.port))
        var output = "Access Key: \(options.key)\n"
        output += "Secret Key: \(options.secret)\n"
        if let path = options.path {
            output += "Directory: \(path)\n"
        }
        let mappings = options.bucketPaths.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        if !mappings.isEmpty {
            output += "Bucket paths: \(mappings)\n"
        }
        let host = options.host ?? "0.0.0.0"
        output += "http://\(host):\(port)\n"
        // Write through FileHandle so the bytes flush even when stdout is
        // redirected (a pipe or file) rather than a line-buffered TTY.
        FileHandle.standardOutput.write(Data(output.utf8))
    }

    static func installSignalHandlers() {
        // DispatchSourceSignal is the reliable way to observe SIGINT/SIGTERM in
        // a `dispatchMain()`-driven process: the source fires on the main queue
        // without the async-signal-safety constraints of a raw signal handler.
        let sources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: handleSignal)
            source.resume()
            return source
        }
        signalSources = sources
    }

    /// Clamps a parsed port integer into `UInt16`, treating out-of-range values
    /// as zero (ephemeral) to avoid trapping. The reference relies on the OS
    /// to reject invalid ports; we mirror that by letting binding fail.
    static func clampingPort(_ value: Int) -> Int {
        guard (0...65535).contains(value) else { return 0 }
        return value
    }
}

/// Signal event handler: stops the active server on a background queue and
/// exits cleanly. Runs on the main dispatch queue via DispatchSourceSignal.
func handleSignal() {
    signalQueue.async {
        Task {
            await activeServer?.stop()
            exit(EXIT_SUCCESS)
        }
    }
}

