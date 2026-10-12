import Foundation

/// Resolves an authenticated request to a bucket root and a contained, validated
/// object key, reproducing the Bun reference bucket detection, path containment,
/// and symlink rejection rules.
///
/// The router is a pure value type over immutable options so its behavior can be
/// unit-tested without a listener or real network request.
struct BucketRouter: Sendable {
    let bucketPaths: [String: String]
    let defaultRoot: String?

    init(bucketPaths: [String: String], defaultRoot: String?) {
        self.bucketPaths = bucketPaths
        self.defaultRoot = defaultRoot
    }

    /// Parses path-style and virtual-host bucket detection from the request
    /// target, returning the bucket name and optional decoded key.
    ///
    /// Mirrors `parseBucketAndKey` in the reference: the host-derived bucket
    /// wins over a differing path-derived bucket, and the entire path then
    /// becomes the key.
    func bucketAndKey(host: String?, path: String) throws -> (bucket: String?, key: String?) {
        let hostBucket = bucketFromHost(host)
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        guard let firstSegment = segments.first else {
            return (hostBucket, nil)
        }

        let decodedFirst = try SigV4Canonicalization.percentDecode(Substring(firstSegment))

        if let hostBucket, decodedFirst != hostBucket {
            guard !hostBucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (nil, nil)
            }
            if hostBucket.contains("/") || hostBucket.contains("\\") {
                throw S3Error(code: "InvalidURI", message: "invalid bucket", status: 400)
            }
            let rawKey = segments.joined(separator: "/")
            let key = rawKey.isEmpty ? nil : try SigV4Canonicalization.percentDecode(Substring(rawKey))
            return (hostBucket, key)
        }

        let bucket = decodedFirst
        var key: String? = nil
        if segments.count > 1 {
            let rawKey = segments.dropFirst().joined(separator: "/")
            key = rawKey.isEmpty ? nil : try SigV4Canonicalization.percentDecode(Substring(rawKey))
        }

        if bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (nil, nil)
        }
        if bucket.contains("/") || bucket.contains("\\") {
            throw S3Error(code: "InvalidURI", message: "invalid bucket", status: 400)
        }
        // The decoded first segment may contain a slash after percent-decode
        // (e.g. `%2F`); the reference catches this via the contains check above
        // only for literal slashes in the already-decoded bucket. Match that.
        return (bucket, key)
    }

    /// Reference `parseBucketFromHost`: no bucket for localhost, `.local`,
    /// IPs, or hosts with two or fewer dot labels; otherwise the first label.
    func bucketFromHost(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") || isIPv4(lower) {
            return nil
        }
        let labels = lower.split(separator: ".").map(String.init)
        if labels.count <= 2 { return nil }
        let bucket = labels[0]
        return bucket.isEmpty ? nil : bucket
    }

    /// Resolves and contains the bucket root, returning it or throwing the
    /// reference-compatible S3 error. Mirrors `resolveBucketPath`.
    func resolveBucketRoot(_ bucket: String) throws -> String {
        if let configured = bucketPaths[bucket] {
            return configured
        }
        guard let defaultRoot else {
            throw S3Error(code: "NoSuchBucket", message: "Bucket not configured", status: 404)
        }
        let resolved = URL(fileURLWithPath: defaultRoot)
            .appendingPathComponent(bucket).standardizedFileURL.path
        if resolved != defaultRoot && !resolved.hasPrefix(defaultRoot + "/") {
            throw S3Error(code: "InvalidURI", message: "bucket escapes data directory", status: 400)
        }
        return resolved
    }

    /// Resolves the contained object path for a key within a bucket root.
    /// Mirrors `resolveObjectPath` plus backslash normalization.
    func resolveObjectPath(bucketRoot: String, key: String) throws -> String {
        let normalized = key.replacingOccurrences(of: "\\", with: "/")
        let resolved = URL(fileURLWithPath: bucketRoot)
            .appendingPathComponent(normalized).standardizedFileURL.path
        if resolved != bucketRoot && !resolved.hasPrefix(bucketRoot + "/") {
            throw S3Error(code: "InvalidURI", message: "key escapes bucket directory", status: 400)
        }
        return resolved
    }

    /// Reference `assertNoSymlinkInPath`: rejects a symlinked bucket root or
    /// any existing object path component. Non-existent components are allowed.
    func assertNoSymlink(bucketRoot: String, objectPath: String) throws {
        let relative = relativePath(from: bucketRoot, to: objectPath)
        if relative.hasPrefix("..") || isAbsolute(relative) {
            throw S3Error(code: "InvalidURI", message: "key escapes bucket directory", status: 400)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: bucketRoot)
        if let type = attributes?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw S3Error(code: "InvalidURI", message: "bucket path is a symlink", status: 400)
        }

        var current = bucketRoot
        for component in relative.split(separator: "/").map(String.init) {
            current = (current as NSString).appendingPathComponent(component)
            let attrs = try? FileManager.default.attributesOfItem(atPath: current)
            if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw S3Error(code: "InvalidURI", message: "symlink not allowed in object path", status: 400)
            }
            // Stop walking once we leave existing components; PUT may create new ones.
            guard FileManager.default.fileExists(atPath: current) else { break }
        }
    }

    private func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let octet = Int(part), (0...255).contains(octet) else { return false }
            // Reject leading zeros like `01`? Reference uses `net.isIP` which
            // accepts them, so accept them here too.
            return true
        }
    }

    private func relativePath(from root: String, to target: String) -> String {
        // Compute a lexical relative path; the reference uses path.relative,
        // but we only need it for the escape/symlink checks below.
        let rootComponents = standardizing(root).split(separator: "/").map(String.init)
        let targetComponents = standardizing(target).split(separator: "/").map(String.init)
        var common = 0
        while common < rootComponents.count, common < targetComponents.count,
              rootComponents[common] == targetComponents[common]
        {
            common += 1
        }
        var result = Array(repeating: "..", count: rootComponents.count - common)
        result.append(contentsOf: targetComponents[common...])
        return result.joined(separator: "/")
    }

    private func standardizing(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/")
    }
}
