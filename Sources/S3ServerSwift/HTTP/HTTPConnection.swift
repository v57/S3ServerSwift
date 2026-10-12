import Foundation
import Network

final class HTTPConnection: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: Handler
    private let onClose: @Sendable () -> Void
    private var parser: HTTPRequestParser
    private var isClosed = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        maximumBodyBytes: Int,
        handler: @escaping Handler,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        parser = HTTPRequestParser(maximumBodyBytes: maximumBodyBytes)
        self.handler = handler
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
        connection.cancel()
        finish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !isClosed else { return }

            do {
                if let request = try parser.append(data ?? Data(), isComplete: isComplete) {
                    let keepAlive = !parser.wantsClose
                    send(handler(request), suppressBody: request.method == "HEAD", keepAlive: keepAlive)
                } else if let error {
                    send(
                        HTTPTransportError.badRequest(error.localizedDescription).response,
                        suppressBody: false,
                        keepAlive: false
                    )
                } else {
                    receive()
                }
            } catch let error as HTTPTransportError {
                send(error.response, suppressBody: false, keepAlive: false)
            } catch {
                send(
                    HTTPResponse(
                        status: 500,
                        headers: ["content-type": "text/plain; charset=utf-8"],
                        body: Data("Internal Server Error".utf8)
                    ),
                    suppressBody: false,
                    keepAlive: false
                )
            }
        }
    }

    private func send(_ response: HTTPResponse, suppressBody: Bool, keepAlive: Bool) {
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
            let requested = Int(min(remaining, 64 * 1024))
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

    /// Continues the connection after a completed response: either resets the
    /// parser and receives the next request, or closes.
    private func finishRequest(keepAlive: Bool) {
        guard keepAlive else {
            close()
            return
        }
        parser.resetForNextRequest()
        receive()
    }

    private func close() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        onClose()
    }
}
