import Foundation
import Network
import Testing
@testable import S3ServerSwift

/// The server as an app embeds it: presigned links, uploads streamed to disk, the hooks, ranges and the in-process
/// storage
@Suite(.serialized) struct EmbeddingTests {
    final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [S3Change] = []
        func append(_ change: S3Change) { lock.withLock { list.append(change) } }
        var all: [S3Change] { lock.withLock { list } }
    }

    struct Running {
        let server: S3Server
        let root: URL
        let presigner: S3Presigner
        let changes: Changes
        var folder: URL { root.appendingPathComponent("hub") }
    }

    func start(
        accepts: (@Sendable (String) -> Bool)? = nil,
        admit: (@Sendable (S3Upload) -> S3Error?)? = nil,
        ended: (@Sendable (S3Upload) -> Void)? = nil
    ) async throws -> Running {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("S3Embedding-\(UUID().uuidString)")
        let changes = Changes()
        let options = try S3ServerOptions(
            host: "::", port: 0, bucketPaths: ["hub": root.appendingPathComponent("hub").path], key: "k", secret: "s"
        )
        let server = S3Server(options: options, hooks: S3ServerHooks(
            acceptsConnection: accepts, admitUpload: admit, changed: { changes.append($0) }, uploadEnded: ended
        ))
        try await server.start()
        let port = try #require(await server.boundPort)
        let presigner = S3Presigner(
            endpoint: URL(string: "http://127.0.0.1:\(port)")!, bucket: "hub", accessKeyID: "k", secretAccessKey: "s"
        )
        return Running(server: server, root: root, presigner: presigner, changes: changes)
    }

    func stop(_ running: Running) async {
        await running.server.stop()
        try? FileManager.default.removeItem(at: running.root)
    }

    func put(_ url: URL, _ body: Data) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func get(_ url: URL, range: String? = nil) async throws -> (Int, Data, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return (http?.statusCode ?? 0, data, http)
    }

    /// Sends raw bytes and returns what the server answers before `timeout`, or nil if it waited for more
    func raw(_ port: UInt16, _ bytes: Data, timeout: Double = 2) async -> String? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "raw")
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            @Sendable func finish(_ value: String?) {
                queue.async {
                    guard !once.done else { return }
                    once.done = true
                    connection.cancel()
                    continuation.resume(returning: value)
                }
            }
            // Reads the answer up to the end of its error document (head and body can come apart)
            final class Answer: @unchecked Sendable { var text = "" }
            let answer = Answer()
            @Sendable func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    answer.text += data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    if answer.text.contains("</Error>") || isComplete || error != nil {
                        finish(answer.text.isEmpty ? nil : answer.text)
                    } else {
                        read()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: bytes, completion: .contentProcessed { _ in })
                    read()
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    @Test func everyAdmittedUploadEndsOnce() async throws {
        final class Ended: @unchecked Sendable {
            private let lock = NSLock()
            private var keys: [String] = []
            func append(_ key: String) { lock.withLock { keys.append(key) } }
            var all: [String] { lock.withLock { keys } }
        }
        let ended = Ended()
        let running = try await start(ended: { ended.append($0.key) })
        defer { Task { await stop(running) } }
        let port = try #require(await running.server.boundPort)
        // Stored
        #expect(try await put(running.presigner.url(method: "PUT", key: "a.txt"), Data("hello".utf8)).0 == 200)
        #expect(ended.all == ["a.txt"])
        // Cut off halfway: the temporary file goes and the upload ends
        let url = running.presigner.url(method: "PUT", key: "cut.bin")
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let head = "PUT \(parts.percentEncodedPath)?\(parts.percentEncodedQuery!) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 100000\r\n\r\n"
        _ = await raw(port, Data(head.utf8) + Data(count: 1000), timeout: 0.5)
        for _ in 0..<40 where ended.all.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(ended.all == ["a.txt", "cut.bin"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: running.folder.path)
        #expect(leftovers == ["a.txt"])
    }

    @Test func refusesAnUnsignedUploadBeforeItsBody() async throws {
        let running = try await start()
        defer { Task { await stop(running) } }
        let port = try #require(await running.server.boundPort)
        // 100 MB announced, 1 KB sent: the answer comes without the rest
        let head = "PUT /hub/big.bin HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 100000000\r\n\r\n"
        let answer = try #require(await raw(port, Data(head.utf8) + Data(count: 1024)))
        #expect(answer.hasPrefix("HTTP/1.1 403"))
        #expect(answer.contains("Missing x-amz-content-sha256"))
        let url = running.presigner.url(method: "PUT", key: "big.bin")
        var bad = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        bad.queryItems = bad.queryItems!.map { $0.name == "X-Amz-Signature" ? URLQueryItem(name: $0.name, value: String(repeating: "0", count: 64)) : $0 }
        let presigned = "PUT \(bad.percentEncodedPath)?\(bad.percentEncodedQuery!) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 100000000\r\n\r\n"
        let refused = try #require(await raw(port, Data(presigned.utf8) + Data(count: 1024)))
        #expect(refused.contains("Signature mismatch"))
        #expect(!FileManager.default.fileExists(atPath: running.folder.appendingPathComponent("big.bin").path))
    }

    @Test func presignedUploadsStreamToDiskAndReportChanges() async throws {
        let running = try await start()
        defer { Task { await stop(running) } }
        let body = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let (status, _) = try await put(running.presigner.url(method: "PUT", key: "folder/clip.mp4"), body)
        #expect(status == 200)
        let stored = running.folder.appendingPathComponent("folder/clip.mp4")
        #expect(try Data(contentsOf: stored) == body)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stored.deletingLastPathComponent().path) == ["clip.mp4"])
        let (again, _) = try await put(running.presigner.url(method: "PUT", key: "folder/clip.mp4"), Data("small".utf8))
        #expect(again == 200)
        let (got, data, _) = try await get(running.presigner.url(method: "GET", key: "folder/clip.mp4"))
        #expect(got == 200)
        #expect(data == Data("small".utf8))
        var request = URLRequest(url: running.presigner.url(method: "DELETE", key: "folder/clip.mp4"))
        request.httpMethod = "DELETE"
        let (_, deleted) = try await URLSession.shared.data(for: request)
        #expect((deleted as? HTTPURLResponse)?.statusCode == 204)
        // The folder it left empty goes too
        #expect(!FileManager.default.fileExists(atPath: stored.deletingLastPathComponent().path))
        #expect(running.changes.all == [
            .stored(bucket: "hub", key: "folder/clip.mp4", size: Int64(body.count), replacedSize: 0),
            .stored(bucket: "hub", key: "folder/clip.mp4", size: 5, replacedSize: Int64(body.count)),
            .deleted(bucket: "hub", key: "folder/clip.mp4", size: 5),
        ])
    }

    @Test func aRefusedUploadGetsTheHooksErrorAndLeavesNothing() async throws {
        let running = try await start(admit: { upload in
            upload.length > 10 ? .storageFull("Over the limit") : nil
        })
        defer { Task { await stop(running) } }
        let (status, data) = try await put(running.presigner.url(method: "PUT", key: "a.bin"), Data(count: 11))
        #expect(status == 507)
        #expect(String(decoding: data, as: UTF8.self).contains("StorageFull"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: running.folder.path).isEmpty)
        let (fits, _) = try await put(running.presigner.url(method: "PUT", key: "a.bin"), Data(count: 10))
        #expect(fits == 200)
    }

    @Test func rangesAnswerPartOfTheObject() async throws {
        let running = try await start()
        defer { Task { await stop(running) } }
        _ = try await put(running.presigner.url(method: "PUT", key: "r.txt"), Data("0123456789".utf8))
        let url = running.presigner.url(method: "GET", key: "r.txt")
        let (status, data, response) = try await get(url, range: "bytes=2-4")
        #expect(status == 206)
        #expect(data == Data("234".utf8))
        #expect(response?.value(forHTTPHeaderField: "Content-Range") == "bytes 2-4/10")
        #expect(try await get(url, range: "bytes=7-").1 == Data("789".utf8))
        #expect(try await get(url, range: "bytes=-3").1 == Data("789".utf8))
        #expect(try await get(url, range: "bytes=10-").0 == 416)
        #expect(try await get(url, range: "bytes=0-1,4-5").0 == 200)
    }

    @Test func refusedAddressesGetNoAnswer() async throws {
        let running = try await start(accepts: { $0 != "127.0.0.1" })
        defer { Task { await stop(running) } }
        await #expect(throws: (any Error).self) {
            _ = try await get(running.presigner.url(method: "GET", key: "x"))
        }
    }

    @Test func expiredAndForeignLinksAreRefused() async throws {
        let running = try await start()
        defer { Task { await stop(running) } }
        _ = try await put(running.presigner.url(method: "PUT", key: "e.txt"), Data("e".utf8))
        let old = running.presigner.url(method: "GET", key: "e.txt", expires: 60, date: Date().addingTimeInterval(-120))
        #expect(try await get(old).0 == 403)
        var other = running.presigner
        other.secretAccessKey = "other"
        #expect(try await get(other.url(method: "GET", key: "e.txt")).0 == 403)
        // A link is for its method
        let read = running.presigner.url(method: "GET", key: "e.txt")
        #expect(try await put(read, Data("x".utf8)).0 == 403)
    }

    @Test func storageListsSizesAndDeletesInProcess() async throws {
        let running = try await start()
        defer { Task { await stop(running) } }
        for key in ["a.txt", "dir/b.txt", "dir/sub/c.txt"] {
            _ = try await put(running.presigner.url(method: "PUT", key: key), Data(key.utf8))
        }
        // An upload in progress isn't listed
        try Data("partial".utf8).write(to: running.folder.appendingPathComponent("dir/d.txt.upload-\(UUID().uuidString)"))
        let storage = running.server.storage
        let top = try storage.list(bucket: "hub", delimiter: "/")
        #expect(top.objects.map(\.key) == ["a.txt"])
        #expect(top.commonPrefixes == ["dir/"])
        let dir = try storage.list(bucket: "hub", prefix: "dir/")
        #expect(dir.objects.map(\.key) == ["dir/b.txt", "dir/sub/c.txt"])
        #expect(try storage.size(bucket: "hub", key: "dir/b.txt") == 9)
        #expect(throws: S3Error.noSuchKey) { try storage.size(bucket: "hub", key: "dir") }
        #expect(throws: S3Error.noSuchKey) { try storage.delete(bucket: "hub", key: "dir") }
        #expect(try storage.usedBytes(bucket: "hub") == 5 + 9 + 13 + 7)
        #expect(try storage.delete(bucket: "hub", key: "dir/sub/c.txt") == 13)
        #expect(!FileManager.default.fileExists(atPath: running.folder.appendingPathComponent("dir/sub").path))
        #expect(try storage.list(bucket: "hub", prefix: "../").objects.isEmpty)
        #expect(throws: S3Error.self) { try storage.size(bucket: "hub", key: "../outside.txt") }
    }
}
