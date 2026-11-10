import Foundation
import Network

/// A reusable, dependency-free S3-compatible HTTP server.
///
/// The transport currently owns listener and connection lifecycle. Request
/// parsing and dispatch are layered onto accepted connections separately.
public actor S3Server {
    public let options: S3ServerOptions
    public let hooks: S3ServerHooks
    /// The storage behind the server, for an app that embeds it to list, size and delete objects in process
    public nonisolated let storage: S3Storage
    public private(set) var boundPort: UInt16?
    /// Listening: `start()` succeeded and neither `stop()` nor a failure (an iPhone app suspended for long) ended it
    public var isRunning: Bool { listener != nil }

    private let queue = DispatchQueue(label: "S3ServerSwift.HTTPServer")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    public init(options: S3ServerOptions, hooks: S3ServerHooks = S3ServerHooks()) {
        self.options = options
        self.hooks = hooks
        storage = S3Storage(options: options)
    }

    /// Creates configured storage roots and starts accepting TCP connections.
    ///
    /// Calling `start()` after the server is already running is a no-op.
    public func start() async throws {
        guard listener == nil else {
            return
        }

        try createConfiguredRoots()

        let requestedPort = NWEndpoint.Port(rawValue: options.port)!
        let parameters = NWParameters.tcp
        let listener: NWListener
        if options.host == "::" {
            // Every address of both families
            listener = try NWListener(using: parameters, on: requestedPort)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(options.host),
                port: requestedPort
            )
            listener = try NWListener(using: parameters)
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task {
                await self.accept(connection)
            }
        }

        let states = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { state in
                continuation.yield(state)
                if case .cancelled = state {
                    continuation.finish()
                }
            }
        }

        listener.start(queue: queue)

        for await state in states {
            switch state {
            case .ready:
                boundPort = listener.port?.rawValue
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    Task {
                        await self.listenerStateChanged(state)
                    }
                }
                return
            case let .failed(error):
                listener.cancel()
                self.listener = nil
                boundPort = nil
                throw error
            case .cancelled:
                self.listener = nil
                boundPort = nil
                throw S3ServerLifecycleError.startCancelled
            default:
                continue
            }
        }

        self.listener = nil
        boundPort = nil
        throw S3ServerLifecycleError.startCancelled
    }

    /// Stops accepting work and cancels every active connection.
    ///
    /// Repeated calls are safe.
    public func stop() async {
        let listener = listener
        listener?.newConnectionHandler = nil

        // Install the terminal-state observer BEFORE canceling so the cancel
        // transition cannot race past the handler and be missed (which would
        // deadlock the await below).
        let terminalStates = listener.map { listener in
            AsyncStream<NWListener.State> { continuation in
                listener.stateUpdateHandler = { state in
                    continuation.yield(state)
                    switch state {
                    case .cancelled, .failed:
                        continuation.finish()
                    default:
                        break
                    }
                }
                if listener.state == .cancelled {
                    continuation.finish()
                }
                if case .failed = listener.state {
                    continuation.finish()
                }
            }
        }

        listener?.cancel()
        self.listener = nil
        boundPort = nil

        let activeConnections = connections.values
        connections.removeAll()
        for connection in activeConnections {
            connection.cancel()
        }

        if let terminalStates {
            for await state in terminalStates {
                switch state {
                case .cancelled, .failed:
                    return
                default:
                    continue
                }
            }
        }
    }

    private func createConfiguredRoots() throws {
        let fileManager = FileManager.default
        var roots = Set(options.bucketPaths.values)
        if let path = options.path {
            roots.insert(path)
        }

        for root in roots {
            try fileManager.createDirectory(
                atPath: root,
                withIntermediateDirectories: true
            )
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        if let acceptsConnection = hooks.acceptsConnection {
            guard let address = Self.address(connection.endpoint), acceptsConnection(address) else {
                connection.cancel()
                return
            }
        }

        let identifier = ObjectIdentifier(connection)
        let verifier = SigV4Verifier(
            accessKeyID: options.key,
            secretAccessKey: options.secret,
            sessionToken: options.sessionToken,
            maximumTimeSkewSeconds: options.maximumTimeSkewSeconds
        )
        let handler = S3RequestHandler(options: options, hooks: hooks)
        let httpConnection = HTTPConnection(
            connection: connection,
            queue: DispatchQueue(label: "S3ServerSwift.HTTPConnection"),
            admit: { head in
                // The signature first, from the head: an unsigned request never gets its body read. The body limit
                // and the upload hooks come after, as in the reference.
                switch verifier.verify(head) {
                case let .failure(error):
                    return .respond(S3Responses.xmlError(
                        S3Error(code: error.code, message: error.message, status: error.status)
                    ))
                case let .success(payload):
                    return handler.admit(head, payload: payload)
                }
            },
            onClose: { [weak self] in
                guard let self else { return }
                Task {
                    await self.removeConnection(identifier)
                }
            }
        )
        connections[identifier] = httpConnection
        httpConnection.start()
    }

    /// The remote address as `S3ServerHooks.acceptsConnection` gets it: no zone, IPv4-mapped IPv6 as IPv4
    static func address(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case let .ipv4(address):
            return "\(address)".split(separator: "%").first.map(String.init)
        case let .ipv6(address):
            if let mapped = address.asIPv4 {
                return "\(mapped)".split(separator: "%").first.map(String.init)
            }
            return "\(address)".split(separator: "%").first.map(String.init)
        case let .name(name, _):
            return name
        @unknown default:
            return nil
        }
    }

    private func removeConnection(_ identifier: ObjectIdentifier) {
        connections.removeValue(forKey: identifier)
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .cancelled, .failed:
            listener = nil
            boundPort = nil
            let activeConnections = connections.values
            connections.removeAll()
            for connection in activeConnections {
                connection.cancel()
            }
        default:
            break
        }
    }
}

public enum S3ServerLifecycleError: Error, Equatable {
    case startCancelled
}
