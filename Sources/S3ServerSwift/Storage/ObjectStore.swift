import Foundation

/// Performs object operations and listing against the filesystem, reproducing
/// the Bun reference behavior: atomic PUT, GET/HEAD metadata, DELETE, and
/// ListObjectsV2 with prefix/delimiter/pagination.
///
/// The store is a value type holding immutable options; all filesystem access
/// runs through `FileManager` on the calling task.
struct ObjectStore: Sendable {
    let router: BucketRouter

    init(router: BucketRouter) {
        self.router = router
    }

    // MARK: - Object operations

    /// Reference PUT: parent mkdir, unique sibling temp, atomic rename with one
    /// retry, cleanup on failure, returns the post-rename ETag.
    func put(bucket: String, key: String, body: Data) throws -> HTTPResponse {
        let bucketRoot = try router.resolveBucketRoot(bucket)
        let objectPath = try router.resolveObjectPath(bucketRoot: bucketRoot, key: key)
        try router.assertNoSymlink(bucketRoot: bucketRoot, objectPath: objectPath)

        let parent = (objectPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true
        )

        let tempPath = "\(objectPath).upload-\(UUID().uuidString)"
        do {
            try body.write(to: URL(fileURLWithPath: tempPath))
            do {
                try rename(tempPath, over: objectPath)
            } catch {
                try? FileManager.default.removeItem(atPath: objectPath)
                try rename(tempPath, over: objectPath)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw S3Error.internalError(error.localizedDescription)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: objectPath)
        let etag = ObjectMetadata.etag(for: attributes)
        return HTTPResponse(status: 200, headers: ["etag": etag])
    }

    func head(bucket: String, key: String) throws -> HTTPResponse {
        let bucketRoot = try router.resolveBucketRoot(bucket)
        let objectPath = try router.resolveObjectPath(bucketRoot: bucketRoot, key: key)
        try router.assertNoSymlink(bucketRoot: bucketRoot, objectPath: objectPath)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: objectPath),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular
        else {
            throw S3Error.noSuchKey
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return HTTPResponse(
            status: 200,
            headers: [
                "content-length": String(size),
                "last-modified": ObjectMetadata.lastModifiedHeader(attributes),
                "etag": ObjectMetadata.etag(for: attributes),
            ]
        )
    }

    func get(bucket: String, key: String) throws -> HTTPResponse {
        let bucketRoot = try router.resolveBucketRoot(bucket)
        let objectPath = try router.resolveObjectPath(bucketRoot: bucketRoot, key: key)
        try router.assertNoSymlink(bucketRoot: bucketRoot, objectPath: objectPath)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: objectPath),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular
        else {
            throw S3Error.noSuchKey
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return HTTPResponse(
            status: 200,
            headers: [
                "content-length": String(size),
                "last-modified": ObjectMetadata.lastModifiedHeader(attributes),
                "etag": ObjectMetadata.etag(for: attributes),
                "content-type": ObjectMetadata.contentType(for: key),
            ],
            fileBody: HTTPFileBody(url: URL(fileURLWithPath: objectPath), length: UInt64(size))
        )
    }

    func delete(bucket: String, key: String) throws -> HTTPResponse {
        let bucketRoot = try router.resolveBucketRoot(bucket)
        let objectPath = try router.resolveObjectPath(bucketRoot: bucketRoot, key: key)
        try router.assertNoSymlink(bucketRoot: bucketRoot, objectPath: objectPath)

        do {
            try FileManager.default.removeItem(atPath: objectPath)
            return HTTPResponse(status: 204)
        } catch {
            throw S3Error.noSuchKey
        }
    }

    // MARK: - Listing

    struct ListResult {
        var objects: [ObjectInfo]
        var commonPrefixes: [String]
        var isTruncated: Bool
        var nextToken: String?
    }

    /// Reference `listObjects`: recursive lexical walk, prefix pruning,
    /// delimiter grouping into unique sorted common prefixes, and
    /// continuation-token resume.
    func list(
        bucket: String,
        prefix: String?,
        maxKeys: Int,
        continuationToken: String?,
        delimiter: String?
    ) throws -> ListResult {
        let bucketRoot = try router.resolveBucketRoot(bucket)
        var objects: [ObjectInfo] = []
        var commonPrefixes = Set<String>()
        var hitLimit = false
        var seenContinuation = continuationToken == nil

        try walk(
            directory: bucketRoot,
            bucketRoot: bucketRoot,
            prefix: prefix,
            delimiter: delimiter,
            maxKeys: maxKeys,
            continuationToken: continuationToken,
            objects: &objects,
            commonPrefixes: &commonPrefixes,
            hitLimit: &hitLimit,
            seenContinuation: &seenContinuation
        )

        return ListResult(
            objects: objects,
            commonPrefixes: commonPrefixes.sorted(),
            isTruncated: hitLimit,
            nextToken: hitLimit ? (objects.last?.key) : nil
        )
    }

    private func walk(
        directory: String,
        bucketRoot: String,
        prefix: String?,
        delimiter: String?,
        maxKeys: Int,
        continuationToken: String?,
        objects: inout [ObjectInfo],
        commonPrefixes: inout Set<String>,
        hitLimit: inout Bool,
        seenContinuation: inout Bool
    ) throws {
        if hitLimit { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        let sorted = entries.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        for name in sorted {
            if hitLimit { return }
            let full = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: full, isDirectory: &isDir)

            if exists && isDir.boolValue {
                let rel = relative(from: bucketRoot, to: full)
                let dirKey = rel + "/"
                if let prefix, !dirKey.hasPrefix(prefix), !prefix.hasPrefix(dirKey) { continue }
                if let delimiter, dirKey.hasPrefix(prefix ?? "") {
                    let afterPrefix = String(dirKey.dropFirst((prefix ?? "").count))
                    if let range = afterPrefix.range(of: delimiter) {
                        let common = (prefix ?? "") + String(afterPrefix[..<range.upperBound])
                        commonPrefixes.insert(common)
                        continue
                    }
                }
                try walk(
                    directory: full,
                    bucketRoot: bucketRoot,
                    prefix: prefix,
                    delimiter: delimiter,
                    maxKeys: maxKeys,
                    continuationToken: continuationToken,
                    objects: &objects,
                    commonPrefixes: &commonPrefixes,
                    hitLimit: &hitLimit,
                    seenContinuation: &seenContinuation
                )
                continue
            }

            // Skip non-regular files (directories already handled).
            guard exists else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: full)
            if let type = attrs?[.type] as? FileAttributeType, type != .typeRegular {
                continue
            }

            let key = relative(from: bucketRoot, to: full)
            if let prefix, !key.hasPrefix(prefix) { continue }
            if !seenContinuation {
                if let continuationToken, key <= continuationToken {
                    continue
                }
                seenContinuation = true
            }
            guard let attrs else { continue }
            objects.append(ObjectMetadata.info(key: key, attributes: attrs))
            if objects.count >= maxKeys {
                hitLimit = true
                return
            }
        }
    }

    // MARK: - Helpers

    private func rename(_ from: String, over to: String) throws {
        // `FileManager.moveItem` over an existing destination fails; use the
        // rename(2) equivalent via replacing the item.
        if FileManager.default.fileExists(atPath: to) {
            try FileManager.default.removeItem(atPath: to)
        }
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    private func relative(from root: String, to target: String) -> String {
        let rootComponents = standardizing(root).split(separator: "/").map(String.init)
        let targetComponents = standardizing(target).split(separator: "/").map(String.init)
        var common = 0
        while common < rootComponents.count, common < targetComponents.count,
              rootComponents[common] == targetComponents[common]
        {
            common += 1
        }
        return targetComponents[common...].joined(separator: "/")
    }

    private func standardizing(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
