import Foundation
import Testing
@testable import S3ServerSwift

@Suite struct BucketRouterTests {
    func makeRouter(
        bucketPaths: [String: String] = [:],
        defaultRoot: String? = nil
    ) -> BucketRouter {
        BucketRouter(bucketPaths: bucketPaths, defaultRoot: defaultRoot)
    }

    // MARK: - Path-style addressing

    @Test func pathNamesTheBucketAndKey() throws {
        let (bucket, key) = try makeRouter().bucketAndKey(path: "/bucket/folder/key.txt")
        #expect(bucket == "bucket")
        #expect(key == "folder/key.txt")
    }

    @Test func bucketWithoutKeyHasNoKey() throws {
        let (bucket, key) = try makeRouter().bucketAndKey(path: "/bucket/")
        #expect(bucket == "bucket")
        #expect(key == nil)
    }

    // MARK: - Bucket/key decoding and validation

    @Test func percentEncodedBucketIsDecoded() throws {
        let router = makeRouter()
        let (bucket, _) = try router.bucketAndKey(path: "/my%20bucket/key.txt")
        #expect(bucket == "my bucket")
    }

    @Test func percentEncodedKeyIsDecoded() throws {
        let router = makeRouter()
        let (_, key) = try router.bucketAndKey(path: "/bucket/a%20b/c.txt")
        #expect(key == "a b/c.txt")
    }

    @Test func invalidPercentEncodingInBucketThrows() {
        let router = makeRouter()
        #expect(throws: CanonicalizationError.invalidPercentEncoding) {
            _ = try router.bucketAndKey(path: "/bucket%ZZ/key.txt")
        }
    }

    @Test func bucketWithSlashThrowsInvalidURI() {
        let router = makeRouter()
        // A decoded bucket containing a literal slash is malformed: `%2F`
        // decodes to `/`, which must be rejected.
        #expect(throws: S3Error(code: "InvalidURI", message: "invalid bucket", status: 400)) {
            _ = try router.bucketAndKey(path: "/a%2Fb/c.txt")
        }
    }

    @Test func bucketWithBackslashThrowsInvalidURI() {
        let router = makeRouter()
        #expect(throws: S3Error(code: "InvalidURI", message: "invalid bucket", status: 400)) {
            _ = try router.bucketAndKey(path: "/a%5Cb/c.txt")
        }
    }

    @Test func missingBucketReturnsNil() throws {
        let router = makeRouter()
        let (bucket, key) = try router.bucketAndKey(path: "/")
        #expect(bucket == nil)
        #expect(key == nil)
    }

    // MARK: - Root resolution

    @Test func explicitBucketRootIsUsed() throws {
        let router = makeRouter(
            bucketPaths: ["photos": "/tmp/photos-root"],
            defaultRoot: "/tmp/default"
        )
        #expect(try router.resolveBucketRoot("photos") == "/tmp/photos-root")
    }

    @Test func fallbackRootIsDefaultRootPlusBucket() throws {
        let router = makeRouter(defaultRoot: "/tmp/default")
        #expect(try router.resolveBucketRoot("videos") == "/tmp/default/videos")
    }

    @Test func unconfiguredBucketWithoutDefaultRootThrowsNoSuchBucket() {
        let router = makeRouter()
        #expect(throws: S3Error(code: "NoSuchBucket", message: "Bucket not configured", status: 404)) {
            _ = try router.resolveBucketRoot("missing")
        }
    }

    @Test func objectPathEscapeThrowsInvalidURI() throws {
        let router = makeRouter(defaultRoot: "/tmp/default")
        let root = try router.resolveBucketRoot("bucket")
        #expect(throws: S3Error(code: "InvalidURI", message: "key escapes bucket directory", status: 400)) {
            _ = try router.resolveObjectPath(bucketRoot: root, key: "../escape.txt")
        }
    }

    @Test func objectPathBackslashesAreNormalized() throws {
        let router = makeRouter(defaultRoot: "/tmp/default")
        let root = try router.resolveBucketRoot("bucket")
        let resolved = try router.resolveObjectPath(bucketRoot: root, key: "a\\b\\c.txt")
        #expect(resolved == "/tmp/default/bucket/a/b/c.txt")
    }

    @Test func objectPathContainedKeyResolves() throws {
        let router = makeRouter(defaultRoot: "/tmp/default")
        let root = try router.resolveBucketRoot("bucket")
        let resolved = try router.resolveObjectPath(bucketRoot: root, key: "dir/file.txt")
        #expect(resolved == "/tmp/default/bucket/dir/file.txt")
    }

    // MARK: - Symlink rejection

    @Test func symlinkedBucketRootIsRejected() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-symlink-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let realRoot = fixture.appendingPathComponent("real").path
        let linkRoot = fixture.appendingPathComponent("link").path
        try FileManager.default.createDirectory(atPath: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkRoot, withDestinationPath: realRoot)

        let router = makeRouter(bucketPaths: ["bucket": linkRoot])
        let objectPath = linkRoot + "/file.txt"
        #expect(throws: S3Error(code: "InvalidURI", message: "bucket path is a symlink", status: 400)) {
            try router.assertNoSymlink(bucketRoot: linkRoot, objectPath: objectPath)
        }
    }

    @Test func symlinkedObjectPathComponentIsRejected() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-symlink-component-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let outside = fixture.appendingPathComponent("outside.txt").path
        try Data("secret".utf8).write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/link.txt",
            withDestinationPath: outside
        )

        let router = makeRouter(bucketPaths: ["bucket": root])
        let objectPath = root + "/link.txt"
        #expect(throws: S3Error(code: "InvalidURI", message: "symlink not allowed in object path", status: 400)) {
            try router.assertNoSymlink(bucketRoot: root, objectPath: objectPath)
        }
    }

    @Test func nonexistentObjectPathComponentsAreAllowed() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-nonexistent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(atPath: fixture.path, withIntermediateDirectories: true)

        let router = makeRouter(bucketPaths: ["bucket": fixture.path])
        // PUT may create new directories, so nonexistent components are fine.
        #expect(throws: Never.self) {
            try router.assertNoSymlink(
                bucketRoot: fixture.path,
                objectPath: fixture.path + "/new/dir/file.txt"
            )
        }
    }
}
