import Foundation
import Network

/// Where a request's body goes, chosen from its head
protocol HTTPBodySink: AnyObject, Sendable {
    /// The next piece of the body; throwing ends the request with `failure`
    func write(_ data: Data) throws
    /// The whole body is in: the answer
    func finish() -> HTTPResponse
    /// The request ended without its whole body
    func cancel()
    /// The answer when `write` threw
    func failure(_ error: Error) -> HTTPResponse
}

/// What the server does with a request once it has the head, before any body byte is read
enum HTTPAdmission: Sendable {
    /// Answers now. A body that wasn't read closes the connection after the answer.
    case respond(HTTPResponse)
    /// Reads the body into memory (callers bound its size from the head), then answers
    case buffer(@Sendable (Data) -> HTTPResponse)
    /// Hands the body over piece by piece as it comes
    case stream(any HTTPBodySink)
}

/// One client connection: reads a request's head, asks `admit` what to do with it, then takes the body (none for an
/// answer that refuses it), answers, and goes on with the next request on keep-alive connections. Its state lives on
/// its own queue.
final class HTTPConnection: @unchecked Sendable {
    typealias Admit = @Sendable (HTTPRequestHead) -> HTTPAdmission

    private enum State {
        case head
        case body(head: HTTPRequestHead, remaining: Int, receiver: Receiver)
        /// Writing the answer
        case answering
    }

    private enum Receiver {
        case buffer(Data, @Sendable (Data) -> HTTPResponse)
        case stream(any HTTPBodySink)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let admit: Admit
    private let onClose: @Sendable () -> Void
    private var parser: HTTPRequestParser
    private var state = State.head
    private var isClosed = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        admit: @escaping Admit,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        parser = HTTPRequestParser(maximumBodyBytes: 0)
        self.admit = admit
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .cancelled, .failed:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        queue.async { [self] in close() }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !isClosed else { return }
            if let error, data?.isEmpty ?? true {
                abandon(HTTPTransportError.badRequest(error.localizedDescription))
                return
            }
            take(data ?? Data(), isComplete: isComplete)
        }
    }

    /// Feeds received bytes to the request in progress
    private func take(_ data: Data, isComplete: Bool) {
        switch state {
        case .head:
            let head: HTTPRequestHead?
            do {
                head = try parser.head(data, isComplete: isComplete)
            } catch {
                abandon(error)
                return
            }
            guard let head else {
                if isComplete { close() } else { receive() }
                return
            }
            begin(head, isComplete: isComplete)
        case let .body(head, remaining, receiver):
            let piece = data.prefix(remaining)
            // Bytes past the body are the next request's
            if data.count > piece.count { parser.push(data.dropFirst(piece.count)) }
            body(head: head, piece: Data(piece), remaining: remaining, receiver: receiver, isComplete: isComplete)
        case .answering:
            break
        }
    }

    /// A request's head is in: answer it at once, or start on its body
    private func begin(_ head: HTTPRequestHead, isComplete: Bool) {
        let receiver: Receiver
        switch admit(head) {
        case let .respond(response):
            // A refused body isn't read, so the connection can't carry another request
            let keepAlive = !head.wantsClose && head.contentLength == 0
            send(response, suppressBody: head.method == "HEAD", keepAlive: keepAlive)
            return
        case let .buffer(complete):
            receiver = .buffer(Data(), complete)
        case let .stream(sink):
            receiver = .stream(sink)
        }
        if head.expectsContinue, head.contentLength > 0, parser.buffer.isEmpty {
            connection.send(content: HTTPResponseWriter.continueHead, completion: .contentProcessed { _ in })
        }
        let buffered = parser.takeBody(upTo: head.contentLength)
        body(head: head, piece: buffered, remaining: head.contentLength, receiver: receiver, isComplete: isComplete)
    }

    private func body(head: HTTPRequestHead, piece: Data, remaining: Int, receiver: Receiver, isComplete: Bool) {
        var receiver = receiver
        if !piece.isEmpty {
            switch receiver {
            case let .buffer(data, complete):
                receiver = .buffer(data + piece, complete)
            case let .stream(sink):
                do {
                    try sink.write(piece)
                } catch {
                    send(sink.failure(error), suppressBody: false, keepAlive: false)
                    return
                }
            }
        }
        let remaining = remaining - piece.count
        guard remaining == 0 else {
            state = .body(head: head, remaining: remaining, receiver: receiver)
            if isComplete {
                if case let .stream(sink) = receiver { sink.cancel() }
                abandon(HTTPTransportError.badRequest("Premature end of request body"))
            } else {
                receive()
            }
            return
        }
        let response = switch receiver {
        case let .buffer(data, complete): complete(data)
        case let .stream(sink): sink.finish()
        }
        send(response, suppressBody: head.method == "HEAD", keepAlive: !head.wantsClose && !isComplete)
    }

    /// Ends the request in progress with a transport error's answer
    private func abandon(_ error: Error) {
        if case let .body(_, _, .stream(sink)) = state { sink.cancel() }
        let response = (error as? HTTPTransportError)?.response ?? HTTPResponse(
            status: 500,
            headers: ["content-type": "text/plain; charset=utf-8"],
            body: Data("Internal Server Error".utf8)
        )
        send(response, suppressBody: false, keepAlive: false)
    }

    private func send(_ response: HTTPResponse, suppressBody: Bool, keepAlive: Bool) {
        state = .answering
        let head = HTTPResponseWriter.serializeHead(response, keepAlive: keepAlive)
        connection.send(content: head, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil, !suppressBody else {
                if error == nil, suppressBody, keepAlive {
                    self.finishRequest(keepAlive: true)
                } else {
                    self.close()
                }
                return
            }
            if let fileBody = response.fileBody {
                sendFile(fileBody, keepAlive: keepAlive)
            } else if response.body.isEmpty {
                finishRequest(keepAlive: keepAlive)
            } else {
                sendBody(response.body, offset: 0, keepAlive: keepAlive)
            }
        })
    }

    private func sendBody(_ body: Data, offset: Int, keepAlive: Bool) {
        let end = min(offset + 64 * 1024, body.count)
        let chunk = body[offset..<end]
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                close()
                return
            }
            if end < body.count {
                sendBody(body, offset: end, keepAlive: keepAlive)
            } else {
                finishRequest(keepAlive: keepAlive)
            }
        })
    }

    private func sendFile(_ body: HTTPFileBody, keepAlive: Bool) {
        do {
            let handle = try FileHandle(forReadingFrom: body.url)
            if body.offset > 0 { try handle.seek(toOffset: body.offset) }
            sendFileChunk(handle, remaining: body.length, keepAlive: keepAlive)
        } catch {
            close()
        }
    }

    private func sendFileChunk(_ handle: FileHandle, remaining: UInt64, keepAlive: Bool) {
        guard remaining > 0 else {
            try? handle.close()
            finishRequest(keepAlive: keepAlive)
            return
        }

        do {
            let requested = Int(min(remaining, 256 * 1024))
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                try? handle.close()
                close()
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else {
                    try? handle.close()
                    return
                }
                guard error == nil else {
                    try? handle.close()
                    close()
                    return
                }
                sendFileChunk(handle, remaining: remaining - UInt64(chunk.count), keepAlive: keepAlive)
            })
        } catch {
            try? handle.close()
            close()
        }
    }

    /// Continues the connection after a completed response: either takes the
    /// next request (already buffered, or yet to come), or closes.
    private func finishRequest(keepAlive: Bool) {
        guard keepAlive, !isClosed else {
            close()
            return
        }
        parser.resetForNextRequest()
        state = .head
        if parser.buffer.isEmpty {
            receive()
        } else {
            take(Data(), isComplete: false)
        }
    }

    private func close() {
        if case let .body(_, _, .stream(sink)) = state { sink.cancel() }
        state = .answering
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        if case let .body(_, _, .stream(sink)) = state { sink.cancel() }
        connection.stateUpdateHandler = nil
        onClose()
    }
}
