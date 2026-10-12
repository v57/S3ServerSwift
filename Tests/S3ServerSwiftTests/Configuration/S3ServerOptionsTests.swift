import Testing
@testable import S3ServerSwift

@Test func negativeLimitsAreNormalized() {
    let options = try! S3ServerOptions(
        key: "key",
        secret: "secret",
        maximumBodyBytes: -1,
        maximumTimeSkewSeconds: -2
    )

    #expect(options.maximumBodyBytes == 0)
    #expect(options.maximumTimeSkewSeconds == 0)
}

@Test func pathsAreExpandedAndNormalized() throws {
    let options = try S3ServerOptions(
        path: "~/data/../objects",
        bucketPaths: ["photos": "relative/photos"],
        key: "key",
        secret: "secret",
        environment: ["HOME": "/tmp/example-home"],
        workingDirectory: "/tmp/work"
    )

    #expect(options.path == "/tmp/example-home/objects")
    #expect(options.bucketPaths == ["photos": "/tmp/work/relative/photos"])
}

@Test func invalidBucketsAndMissingHomeAreRejected() {
    #expect(throws: S3ServerOptionsError.invalidBucket) {
        try S3ServerOptions(bucketPaths: ["bad/name": "/tmp/data"], key: "key", secret: "secret")
    }
    #expect(throws: S3ServerOptionsError.homeRequired) {
        try S3ServerOptions(path: "~/data", key: "key", secret: "secret", environment: [:])
    }
}
