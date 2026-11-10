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

    /// An upload on its way: its body goes to `tempPath`, a sibling of the object, and `commit` renames it over the
    /// object once the body is complete and checked
    struct PendingUpload: Sendable {
        var bucket: String
        var key: String
        var objectPath: String
        var tempPath: String
        /// The size of the object it replaces, 0 for a new one
        var replacedSize: Int64
    }

    /// Reference PUT's checks before any byte is written: a contained, symlink-free path and its parent folders
    func prepareUpload(bucket: String, key: String) throws -> PendingUpload {
        let bucketRoot = try router.resolveBucketRoot(bucket)
        let objectPath = try router.resolveObjectPath(bucketRoot: bucketRoot, key: key)
        try router.assertNoSymlink(bucketRoot: bucketRoot, objectPath: objectPath)
        guard objectPath != bucketRoot else { throw S3Error.keyRequired }

        let parent = (objectPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            throw S3Error.internalError(error.localizedDescription)
        }
        return PendingUpload(
            bucket: bucket,
            key: key,
            objectPath: objectPath,
            tempPath: "\(objectPath)\(Self.uploadMarker)\(UUID().uuidString)",
            replacedSize: regularFileSize(objectPath) ?? 0
        )
    }

    /// Renames the finished upload over the object (one retry after removing it) and returns the post-rename ETag
    func commit(_ upload: PendingUpload) throws -> (response: HTTPResponse, size: Int64) {
        do {
            do {
                try rename(upload.tempPath, over: upload.objectPath)
            } catch {
                try? FileManager.default.removeItem(atPath: upload.objectPath)
                try rename(upload.tempPath, over: upload.objectPath)
            }
        } catch {
            discard(upload)
            throw S3Error.internalError(error.localizedDescription)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: upload.objectPath)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return (HTTPResponse(status: 200, headers: ["etag": ObjectMetadata.etag(for: attributes)]), size)
    }

    func discard(_ upload: PendingUpload) {
        try? FileManager.default.removeItem(atPath: upload.tempPath)
    }

    /// A whole PUT with its body in memory
    func put(bucket: String, key: String, body: Data) throws -> HTTPResponse {
        let upload = try prepareUpload(bucket: bucket, key: key)
        do {
            try body.write(to: URL(fileURLWithPath: upload.tempPath))
        } catch {
            discard(upload)
            throw S3Error.internalError(error.localizedDescription)
        }
        return try commit(upload).response
    }

    /// Temporary upload files are `<object>.upload-<UUID>`; listings skip them
    static let uploadMarker = ".upload-"

    static func isUploadInProgress(_ name: String) -> Bool {
        guard let range = name.range(of: uploadMarker, options: .backwards) else { return false }
        return UUID(uuidString: String(name[range.upperBound...])) != nil
    }

    /// The size of a regular file, nil for anything else
    func regularFileSize(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular
        else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
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
                "accept-ranges": "bytes",
            ]
        )
    }

    /// The object, or the part `range` (a `Range` header's value) asks for: one range of `bytes=a-b`, `bytes=a-` or
    /// `bytes=-n` answers 206, one past the end 416, anything else the whole object
    func get(bucket: String, key: String, range: String? = nil) throws -> HTTPResponse {
        let bucketRoot = try router.resolveBucketRoot(bucket)
        let objectPath = try router.resolveObjectPath(bucketRoot: bucketRoot, key: key)
        try router.assertNoSymlink(bucketRoot: bucketRoot, objectPath: objectPath)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: objectPath),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular
        else {
            throw S3Error.noSuchKey
        }
        let size = UInt64(max(0, (attributes[.size] as? NSNumber)?.int64Value ?? 0))
        var headers = [
            "last-modified": ObjectMetadata.lastModifiedHeader(attributes),
            "etag": ObjectMetadata.etag(for: attributes),
            "content-type": ObjectMetadata.contentType(for: key),
            "accept-ranges": "bytes",
        ]
        let url = URL(fileURLWithPath: objectPath)
        switch ByteRange.parse(range, size: size) {
        case .none:
            headers["content-length"] = String(size)
            return HTTPResponse(status: 200, headers: headers, fileBody: HTTPFileBody(url: url, length: size))
        case let .some(.satisfiable(first, last)):
            headers["content-length"] = String(last - first + 1)
            headers["content-range"] = "bytes \(first)-\(last)/\(size)"
            return HTTPResponse(
                status: 206,
                headers: headers,
                fileBody: HTTPFileBody(url: url, offset: first, length: last - first + 1)
            )
        case .some(.unsatisfiable):
            var response = S3Responses.xmlError(S3Error(
                code: "InvalidRange", message: "The requested range is not satisfiable", status: 416
            ))
            response.headers["content-range"] = "bytes */\(size)"
            return response
        }
    }

    func delete(bucket: String, key: String) throws -> HTTPResponse {
        let bucketRoot = try router.resolveBucketRoot(bucket)
        let objectPath = try router.resolveObjectPath(bucketRoot: bucketRoot, key: key)
        try router.assertNoSymlink(bucketRoot: bucketRoot, objectPath: objectPath)

        _ = try deleteObject(bucketRoot: bucketRoot, objectPath: objectPath)
        return HTTPResponse(status: 204)
    }

    /// Removes one object, never a folder (a key naming a folder is no object), and the folders it leaves empty up
    /// to the bucket's root. Returns the size it freed.
    func deleteObject(bucket: String, key: String) throws -> Int64 {
        let bucketRoot = try router.resolveBucketRoot(bucket)
        let objectPath = try router.resolveObjectPath(bucketRoot: bucketRoot, key: key)
        try router.assertNoSymlink(bucketRoot: bucketRoot, objectPath: objectPath)
        return try deleteObject(bucketRoot: bucketRoot, objectPath: objectPath)
    }

    private func deleteObject(bucketRoot: String, objectPath: String) throws -> Int64 {
        guard objectPath != bucketRoot, let size = regularFileSize(objectPath) else { throw S3Error.noSuchKey }
        do {
            try FileManager.default.removeItem(atPath: objectPath)
        } catch {
            throw S3Error.noSuchKey
        }
        var folder = (objectPath as NSString).deletingLastPathComponent
        while folder.hasPrefix(bucketRoot + "/"),
              (try? FileManager.default.contentsOfDirectory(atPath: folder))?.isEmpty == true
        {
            try? FileManager.default.removeItem(atPath: folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        return size
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

            // Skip non-regular files (directories already handled) and uploads in progress.
            guard exists, !Self.isUploadInProgress(name) else { continue }
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

/// A `Range` header with one byte range, resolved against the object's size
enum ByteRange: Equatable {
    case satisfiable(first: UInt64, last: UInt64)
    case unsatisfiable

    /// nil: no range, several ranges or a malformed one, which all get the whole object
    static func parse(_ value: String?, size: UInt64) -> ByteRange? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), value.lowercased().hasPrefix("bytes=") else {
            return nil
        }
        let spec = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let start = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let end = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        guard start.allSatisfy(\.isASCIIDigit), end.allSatisfy(\.isASCIIDigit) else { return nil }
        if start.isEmpty {
            // The last n bytes
            guard let count = UInt64(end) else { return nil }
            guard count > 0, size > 0 else { return .unsatisfiable }
            return .satisfiable(first: size - min(count, size), last: size - 1)
        }
        guard let first = UInt64(start) else { return nil }
        guard first < size else { return .unsatisfiable }
        if end.isEmpty { return .satisfiable(first: first, last: size - 1) }
        guard let last = UInt64(end), last >= first else { return nil }
        return .satisfiable(first: first, last: min(last, size - 1))
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
