import Foundation
import Testing
@testable import S3ServerSwift

@Suite struct ObjectStoreTests {
    /// Creates a fresh temporary bucket root and an ObjectStore pointing at it.
    private func makeStore(
        bucket: String = "testbucket",
        bucketPaths: [String: String] = [:],
        defaultRoot: String? = nil
    ) throws -> (store: ObjectStore, root: String) {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("object-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: fixture.path, withIntermediateDirectories: true)
        let root: String
        if let configured = bucketPaths[bucket] {
            root = configured
        } else if let defaultRoot {
            root = (defaultRoot as NSString).appendingPathComponent(bucket)
        } else {
            root = (fixture.path as NSString).appendingPathComponent(bucket)
        }
        var paths = bucketPaths
        if paths[bucket] == nil, defaultRoot == nil {
            // Give the store a direct mapping for the test bucket so a default
            // root is not required to resolve it.
            paths[bucket] = root
        }
        let store = ObjectStore(
            router: BucketRouter(bucketPaths: paths, defaultRoot: defaultRoot)
        )
        return (store, root)
    }

    private func temporaryDirectory() throws -> String {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("object-store-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: fixture.path, withIntermediateDirectories: true)
        return fixture.path
    }

    // MARK: - PUT

    @Test func putStoresTextObjectAndReturnsQuotedEtag() throws {
        let (store, root) = try makeStore()
        let response = try store.put(bucket: "testbucket", key: "hello.txt", body: Data("hello world".utf8))
        #expect(response.status == 200)
        let etag = try #require(response.headers["etag"])
        #expect(etag.hasPrefix("\""))
        #expect(etag.hasSuffix("\""))
        let stored = try Data(contentsOf: URL(fileURLWithPath: root + "/hello.txt"))
        #expect(String(data: stored, encoding: .utf8) == "hello world")
    }

    @Test func putOverwritesAtomically() throws {
        let (store, _) = try makeStore()
        _ = try store.put(bucket: "testbucket", key: "overwrite.txt", body: Data("first".utf8))
        let second = try store.put(bucket: "testbucket", key: "overwrite.txt", body: Data("second".utf8))
        #expect(second.status == 200)
        let response = try store.get(bucket: "testbucket", key: "overwrite.txt")
        let fileBody = try #require(response.fileBody)
        let data = try Data(contentsOf: fileBody.url)
        #expect(String(data: data, encoding: .utf8) == "second")
    }

    @Test func putCreatesParentDirectories() throws {
        let (store, root) = try makeStore()
        _ = try store.put(bucket: "testbucket", key: "a/b/c/deep.txt", body: Data("deep".utf8))
        #expect(FileManager.default.fileExists(atPath: root + "/a/b/c/deep.txt"))
    }

    @Test func putWritesBinaryBody() throws {
        let (store, root) = try makeStore()
        let bytes = Data([0x00, 0x01, 0xFE, 0xFF])
        _ = try store.put(bucket: "testbucket", key: "bin.dat", body: bytes)
        let data = try Data(contentsOf: URL(fileURLWithPath: root + "/bin.dat"))
        #expect(data == bytes)
    }

    @Test func putRejectsTraversalKey() throws {
        let (store, _) = try makeStore()
        #expect(throws: S3Error(code: "InvalidURI", message: "key escapes bucket directory", status: 400)) {
            try store.put(bucket: "testbucket", key: "../escape.txt", body: Data())
        }
    }

    @Test func putLeavesNoTempFilesOnSuccess() throws {
        let (store, root) = try makeStore()
        _ = try store.put(bucket: "testbucket", key: "clean.txt", body: Data("data".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root)
            .filter { $0.contains(".upload-") }
        #expect(leftovers.isEmpty)
    }

    // MARK: - GET / HEAD

    @Test func getReturnsBytesMetadataAndMimeType() throws {
        let (store, _) = try makeStore()
        _ = try store.put(bucket: "testbucket", key: "doc.txt", body: Data("content".utf8))
        let response = try store.get(bucket: "testbucket", key: "doc.txt")
        #expect(response.status == 200)
        let fileBody = try #require(response.fileBody)
        let data = try Data(contentsOf: fileBody.url)
        #expect(String(data: data, encoding: .utf8) == "content")
        #expect(response.headers["content-type"] == ObjectMetadata.contentType(for: "doc.txt"))
        #expect(response.headers["last-modified"] != nil)
        #expect(response.headers["etag"] != nil)
        #expect(response.headers["content-length"] == "7")
    }

    @Test func getFallsBackToOctetStreamForUnknownExtension() throws {
        let (store, _) = try makeStore()
        _ = try store.put(bucket: "testbucket", key: "unknown.zzz", body: Data("x".utf8))
        let response = try store.get(bucket: "testbucket", key: "unknown.zzz")
        #expect(response.headers["content-type"] == "application/octet-stream")
    }

    @Test func getMissingObjectThrowsNoSuchKey() throws {
        let (store, _) = try makeStore()
        #expect(throws: S3Error(code: "NoSuchKey", message: "Object not found", status: 404)) {
            try store.get(bucket: "testbucket", key: "missing.txt")
        }
    }

    @Test func headMatchesGetMetadataWithoutBody() throws {
        let (store, _) = try makeStore()
        _ = try store.put(bucket: "testbucket", key: "meta.txt", body: Data("metadata".utf8))
        let head = try store.head(bucket: "testbucket", key: "meta.txt")
        let get = try store.get(bucket: "testbucket", key: "meta.txt")
        #expect(head.status == 200)
        #expect(head.headers["etag"] == get.headers["etag"])
        #expect(head.headers["last-modified"] == get.headers["last-modified"])
        #expect(head.headers["content-length"] == get.headers["content-length"])
        #expect(head.fileBody == nil)
    }

    @Test func headMissingObjectThrowsNoSuchKey() throws {
        let (store, _) = try makeStore()
        #expect(throws: S3Error(code: "NoSuchKey", message: "Object not found", status: 404)) {
            try store.head(bucket: "testbucket", key: "missing.txt")
        }
    }

    // MARK: - DELETE

    @Test func deleteRemovesExistingObject() throws {
        let (store, root) = try makeStore()
        _ = try store.put(bucket: "testbucket", key: "gone.txt", body: Data("bye".utf8))
        let response = try store.delete(bucket: "testbucket", key: "gone.txt")
        #expect(response.status == 204)
        #expect(!FileManager.default.fileExists(atPath: root + "/gone.txt"))
    }

    @Test func deleteMissingObjectThrowsNoSuchKey() throws {
        let (store, _) = try makeStore()
        #expect(throws: S3Error(code: "NoSuchKey", message: "Object not found", status: 404)) {
            try store.delete(bucket: "testbucket", key: "missing.txt")
        }
    }

    // MARK: - ETag consistency

    @Test func etagIsConsistentAcrossOperations() throws {
        let (store, _) = try makeStore()
        let putResponse = try store.put(bucket: "testbucket", key: "consistent.txt", body: Data("same".utf8))
        let putEtag = try #require(putResponse.headers["etag"])
        let getEtag = try #require(try store.get(bucket: "testbucket", key: "consistent.txt").headers["etag"])
        let headEtag = try #require(try store.head(bucket: "testbucket", key: "consistent.txt").headers["etag"])
        // All operations must derive the ETag from the same size:mtimeMs formula.
        #expect(getEtag == putEtag)
        #expect(headEtag == putEtag)
        #expect(getEtag.hasPrefix("\""))
        #expect(getEtag.hasSuffix("\""))
        #expect(getEtag.utf8.count == 34) // quoted 32-char lowercase hex
    }

    // MARK: - Unconfigured bucket

    @Test func unconfiguredBucketThrowsNoSuchBucket() throws {
        let (store, _) = try makeStore(bucketPaths: ["only": "/tmp/only-root"])
        #expect(throws: S3Error(code: "NoSuchBucket", message: "Bucket not configured", status: 404)) {
            try store.get(bucket: "other", key: "x.txt")
        }
    }

    // MARK: - Symlink rejection

    @Test func putRejectsSymlinkedParentComponent() throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        let outside = fixture + "/outside.txt"
        try Data("secret".utf8).write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(
            atPath: fixture + "/link.txt",
            withDestinationPath: outside
        )
        let store = ObjectStore(
            router: BucketRouter(bucketPaths: ["testbucket": fixture], defaultRoot: nil)
        )
        #expect(throws: S3Error(code: "InvalidURI", message: "symlink not allowed in object path", status: 400)) {
            try store.put(bucket: "testbucket", key: "link.txt/child.txt", body: Data("x".utf8))
        }
    }
}
