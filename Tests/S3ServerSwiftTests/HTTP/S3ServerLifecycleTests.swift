import Foundation
import Testing
@testable import S3ServerSwift

@Test func lifecycleCreatesRootsBindsEphemeralPortAndStopsIdempotently() async throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("S3ServerSwift-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    let defaultRoot = fixtureRoot.appendingPathComponent("default").path
    let mappedRoot = fixtureRoot.appendingPathComponent("mapped").path
    let options = try S3ServerOptions(
        host: "127.0.0.1",
        port: 0,
        path: defaultRoot,
        bucketPaths: ["mapped": mappedRoot],
        key: "key",
        secret: "secret"
    )
    let server = S3Server(options: options)

    try await server.start()
    let port = await server.boundPort

    #expect(port != nil)
    #expect(port != 0)
    #expect(FileManager.default.fileExists(atPath: defaultRoot))
    #expect(FileManager.default.fileExists(atPath: mappedRoot))

    await server.stop()
    await server.stop()
    #expect(await server.boundPort == nil)
}

@Test func stopReleasesTheBoundPort() async throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("S3ServerSwift-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    let firstOptions = try S3ServerOptions(
        host: "127.0.0.1",
        port: 0,
        path: fixtureRoot.path,
        key: "key",
        secret: "secret"
    )
    let firstServer = S3Server(options: firstOptions)
    try await firstServer.start()
    let firstPort = try #require(await firstServer.boundPort)
    await firstServer.stop()

    let secondOptions = try S3ServerOptions(
        host: "127.0.0.1",
        port: firstPort,
        path: fixtureRoot.path,
        key: "key",
        secret: "secret"
    )
    let secondServer = S3Server(options: secondOptions)
    try await secondServer.start()
    #expect(await secondServer.boundPort == firstPort)
    await secondServer.stop()
}

@Test func parallelConnectionsReceiveResponsesBeforeShutdown() async throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("S3ServerSwift-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    let options = try S3ServerOptions(
        host: "127.0.0.1",
        port: 0,
        path: fixtureRoot.path,
        key: "key",
        secret: "secret"
    )
    let server = S3Server(options: options)
    try await server.start()
    let port = try #require(await server.boundPort)
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/"))

    try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<8 {
            group.addTask {
                let (_, response) = try await URLSession.shared.data(from: url)
                return (response as? HTTPURLResponse)?.statusCode ?? 0
            }
        }
        for try await status in group {
            #expect(status == 403)
        }
    }

    await server.stop()
}
