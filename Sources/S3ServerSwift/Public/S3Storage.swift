import Foundation

/// The server's storage in process, for an app that embeds the server: the same buckets, path checks and listing
/// as requests get, without HTTP or signatures. `S3Server.storage` is the running server's.
public struct S3Storage: Sendable {
    let store: ObjectStore

    public init(options: S3ServerOptions) {
        store = ObjectStore(router: BucketRouter(bucketPaths: options.bucketPaths, defaultRoot: options.path))
    }

    public struct Object: Sendable, Equatable {
        public var key: String
        public var size: Int64
        /// ISO 8601 with milliseconds in UTC, as ListObjectsV2 has it
        public var lastModified: String
        public var etag: String
    }

    public struct Listing: Sendable, Equatable {
        public var objects: [Object]
        /// With a delimiter: the folders under the prefix, each ending in the delimiter
        public var commonPrefixes: [String]
        public var isTruncated: Bool
        public var nextContinuationToken: String?
    }

    /// ListObjectsV2: objects under `prefix` in key order, grouped into common prefixes by `delimiter`, at most
    /// `maxKeys` (1…1000) from after `continuationToken`
    public func list(
        bucket: String,
        prefix: String? = nil,
        delimiter: String? = nil,
        maxKeys: Int = 1000,
        continuationToken: String? = nil
    ) throws -> Listing {
        let result = try store.list(
            bucket: bucket,
            prefix: prefix?.isEmpty == true ? nil : prefix,
            maxKeys: min(max(maxKeys, 1), 1000),
            continuationToken: continuationToken,
            delimiter: delimiter?.isEmpty == true ? nil : delimiter
        )
        return Listing(
            objects: result.objects.map {
                Object(key: $0.key, size: $0.size, lastModified: $0.lastModified, etag: $0.etag)
            },
            commonPrefixes: result.commonPrefixes,
            isTruncated: result.isTruncated,
            nextContinuationToken: result.nextToken
        )
    }

    /// The object's size; `S3Error` NoSuchKey when there's none
    public func size(bucket: String, key: String) throws -> Int64 {
        let root = try store.router.resolveBucketRoot(bucket)
        let path = try store.router.resolveObjectPath(bucketRoot: root, key: key)
        try store.router.assertNoSymlink(bucketRoot: root, objectPath: path)
        guard path != root, let size = store.regularFileSize(path) else { throw S3Error.noSuchKey }
        return size
    }

    /// Deletes one object (never a folder) and the folders it leaves empty; returns the bytes it freed.
    /// `S3Error` NoSuchKey when there's none.
    @discardableResult
    public func delete(bucket: String, key: String) throws -> Int64 {
        try store.deleteObject(bucket: bucket, key: key)
    }

    /// Bytes the bucket's files take, uploads in progress included
    public func usedBytes(bucket: String) throws -> Int64 {
        let root = try store.router.resolveBucketRoot(bucket)
        guard let files = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
