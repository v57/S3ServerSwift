import Foundation
import Testing
@testable import S3ServerSwift

@Suite struct ListObjectsTests {
    /// Creates a temporary root mapped to `testbucket` and an ObjectStore.
    private func makeStore() throws -> (store: ObjectStore, root: String) {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("list-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: fixture.path, withIntermediateDirectories: true)
        let root = (fixture.path as NSString).appendingPathComponent("testbucket")
        let store = ObjectStore(
            router: BucketRouter(bucketPaths: ["testbucket": root], defaultRoot: nil)
        )
        return (store, root)
    }

    private func write(
        _ store: ObjectStore,
        key: String,
        data: Data = Data("x".utf8)
    ) throws {
        _ = try store.put(bucket: "testbucket", key: key, body: data)
    }

    // MARK: - Basic enumeration

    @Test func emptyBucketListsNothing() throws {
        let (store, _) = try makeStore()
        let result = try store.list(
            bucket: "testbucket",
            prefix: nil,
            maxKeys: 1000,
            continuationToken: nil,
            delimiter: nil
        )
        #expect(result.objects.isEmpty)
        #expect(result.commonPrefixes.isEmpty)
        #expect(!result.isTruncated)
        #expect(result.nextToken == nil)
    }

    @Test func listsFilesInLexicalOrder() throws {
        let (store, _) = try makeStore()
        try write(store, key: "b.txt")
        try write(store, key: "a.txt")
        try write(store, key: "c.txt")
        let result = try store.list(bucket: "testbucket", prefix: nil, maxKeys: 1000, continuationToken: nil, delimiter: nil)
        #expect(result.objects.map(\.key) == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func nestedKeysAreRecursivelyEnumerated() throws {
        let (store, _) = try makeStore()
        try write(store, key: "dir1/deep/file.txt")
        try write(store, key: "root.txt")
        let result = try store.list(bucket: "testbucket", prefix: nil, maxKeys: 1000, continuationToken: nil, delimiter: nil)
        #expect(result.objects.map(\.key) == ["dir1/deep/file.txt", "root.txt"])
    }

    // MARK: - Prefix

    @Test func prefixFiltersResults() throws {
        let (store, _) = try makeStore()
        try write(store, key: "pfx/one.txt")
        try write(store, key: "other/two.txt")
        let result = try store.list(bucket: "testbucket", prefix: "pfx/", maxKeys: 1000, continuationToken: nil, delimiter: nil)
        #expect(result.objects.map(\.key) == ["pfx/one.txt"])
    }

    // MARK: - Delimiter

    @Test func delimiterGroupsCommonPrefixesAtRoot() throws {
        let (store, _) = try makeStore()
        try write(store, key: "root.txt")
        try write(store, key: "dir1/file1.txt")
        try write(store, key: "dir1/subdir/file2.txt")
        try write(store, key: "dir2/file3.txt")
        let result = try store.list(bucket: "testbucket", prefix: nil, maxKeys: 1000, continuationToken: nil, delimiter: "/")
        #expect(result.objects.map(\.key) == ["root.txt"])
        #expect(result.commonPrefixes == ["dir1/", "dir2/"])
    }

    @Test func delimiterWithPrefixGroupsDeeper() throws {
        let (store, _) = try makeStore()
        try write(store, key: "delim/root.txt")
        try write(store, key: "delim/dir1/file1.txt")
        try write(store, key: "delim/dir1/subdir/file2.txt")
        try write(store, key: "delim/dir2/file3.txt")
        let result = try store.list(bucket: "testbucket", prefix: "delim/", maxKeys: 1000, continuationToken: nil, delimiter: "/")
        #expect(result.objects.map(\.key) == ["delim/root.txt"])
        #expect(result.commonPrefixes == ["delim/dir1/", "delim/dir2/"])
    }

    @Test func delimiterCommonPrefixesAreUniqueAndSorted() throws {
        let (store, _) = try makeStore()
        try write(store, key: "z/f.txt")
        try write(store, key: "a/f.txt")
        try write(store, key: "a/g.txt")
        let result = try store.list(bucket: "testbucket", prefix: nil, maxKeys: 1000, continuationToken: nil, delimiter: "/")
        #expect(result.commonPrefixes == ["a/", "z/"])
    }

    // MARK: - max-keys / truncation

    @Test func maxKeysLimitsResultsAndSetsTruncation() throws {
        let (store, _) = try makeStore()
        for index in 0..<5 {
            try write(store, key: "maxkeys/f\(index).txt")
        }
        let result = try store.list(bucket: "testbucket", prefix: "maxkeys/", maxKeys: 2, continuationToken: nil, delimiter: nil)
        #expect(result.objects.count == 2)
        #expect(result.isTruncated)
        #expect(result.nextToken == "maxkeys/f1.txt")
    }

    @Test func continuationTokenResumesAfterLastKey() throws {
        let (store, _) = try makeStore()
        for index in 0..<4 {
            try write(store, key: "cont/f\(index).txt")
        }
        let first = try store.list(bucket: "testbucket", prefix: "cont/", maxKeys: 2, continuationToken: nil, delimiter: nil)
        #expect(first.isTruncated)
        let token = try #require(first.nextToken)
        // The reference sets `hitLimit` when results reach maxKeys exactly, so
        // a request with maxKeys 2 and exactly 2 remaining is still truncated.
        let second = try store.list(bucket: "testbucket", prefix: "cont/", maxKeys: 3, continuationToken: token, delimiter: nil)
        #expect(second.objects.map(\.key) == ["cont/f2.txt", "cont/f3.txt"])
        #expect(!second.isTruncated)
    }

    @Test func continuationTokenExcludesTokenKeyItself() throws {
        let (store, _) = try makeStore()
        try write(store, key: "tok/a.txt")
        try write(store, key: "tok/b.txt")
        try write(store, key: "tok/c.txt")
        let result = try store.list(bucket: "testbucket", prefix: "tok/", maxKeys: 1, continuationToken: "tok/a.txt", delimiter: nil)
        // Resume strictly after the token: b.txt first.
        #expect(result.objects.map(\.key) == ["tok/b.txt"])
    }

    @Test func largeMaxKeysCapsAtReferenceLimit() throws {
        let (store, _) = try makeStore()
        for index in 0..<5 {
            try write(store, key: "cap/f\(index).txt")
        }
        // The caller clamps to 1000, but a value above the object count still
        // returns everything without truncation.
        let result = try store.list(bucket: "testbucket", prefix: "cap/", maxKeys: 1000, continuationToken: nil, delimiter: nil)
        #expect(result.objects.count == 5)
        #expect(!result.isTruncated)
    }

    // MARK: - Non-regular files

    @Test func listingSkipsNonRegularFiles() throws {
        let (store, root) = try makeStore()
        try write(store, key: "regular.txt")
        try Data("link target".utf8).write(to: URL(fileURLWithPath: root + "/target.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/link.txt",
            withDestinationPath: root + "/target.txt"
        )
        let result = try store.list(bucket: "testbucket", prefix: nil, maxKeys: 1000, continuationToken: nil, delimiter: nil)
        #expect(result.objects.map(\.key) == ["regular.txt", "target.txt"])
    }
}
