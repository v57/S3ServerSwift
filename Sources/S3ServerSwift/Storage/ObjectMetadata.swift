import Foundation

/// Shared object metadata derivation matching the Bun reference formulas.
///
/// The reference computes ETags from `MD5("<size>:<stats.mtimeMs>")` where
/// `mtimeMs` is the file mtime in milliseconds as a full-precision float
/// (Bun exposes the underlying seconds + nanoseconds as `seconds*1000`).
enum ObjectMetadata {
    /// Returns `stats.mtime` in milliseconds using the same
    /// `seconds*1000 + nanoseconds/1_000_000` composition as `stats.mtimeMs`,
    /// without losing sub-millisecond precision.
    static func mtimeMilliseconds(_ attributes: [FileAttributeKey: Any]) -> Double {
        let date = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return date.timeIntervalSince1970 * 1000
    }

    /// Quoted lowercase MD5 hex of `"<size>:<mtimeMs>"`, matching the reference.
    static func etag(size: Int64, mtimeMilliseconds: Double) -> String {
        let payload = Data("\(size):\(mtimeMilliseconds)".utf8)
        return "\"\(CryptoPrimitives.md5Hex(payload))\""
    }

    static func etag(for attributes: [FileAttributeKey: Any]) -> String {
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return etag(size: size, mtimeMilliseconds: mtimeMilliseconds(attributes))
    }

    /// RFC 1123 / HTTP Last-Modified in fixed en-US_POSIX UTC, matching
    /// `Date.prototype.toUTCString`.
    static func lastModifiedHeader(_ attributes: [FileAttributeKey: Any]) -> String {
        let date = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return SigV4Dates.httpLastModified(date)
    }

    /// ISO-8601 with milliseconds in fixed UTC, matching `Date.prototype.toISOString`.
    static func listLastModified(_ attributes: [FileAttributeKey: Any]) -> String {
        let date = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return SigV4Dates.iso8601ListDate(date)
    }

    /// System-derived MIME type matching Bun's `file.type`, falling back to
    /// `application/octet-stream` when no mapping is known.
    static func contentType(for key: String) -> String {
        let mapped = mappedContentType(for: key)
        return mapped ?? "application/octet-stream"
    }

    /// A small extension→content-type table covering the cases the reference
    /// test suite and common clients encounter. Unknown extensions fall back to
    /// `application/octet-stream`, matching the reference.
    private static func mappedContentType(for key: String) -> String? {
        let ext = (key as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        switch ext {
        case "txt": return "text/plain;charset=utf-8"
        case "json": return "application/json;charset=utf-8"
        case "html", "htm": return "text/html;charset=utf-8"
        case "js", "mjs": return "text/javascript;charset=utf-8"
        case "css": return "text/css;charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "gz": return "application/gzip"
        case "tar": return "application/x-tar"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "xml": return "application/xml;charset=utf-8"
        case "csv": return "text/csv;charset=utf-8"
        case "md": return "text/markdown;charset=utf-8"
        case "wasm": return "application/wasm"
        default: return nil
        }
    }
}

extension ObjectMetadata {
    /// Convenience for a fully resolved `ObjectInfo` used by listing.
    static func info(key: String, attributes: [FileAttributeKey: Any]) -> ObjectInfo {
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return ObjectInfo(
            key: key,
            size: size,
            lastModified: listLastModified(attributes),
            etag: etag(for: attributes)
        )
    }
}

struct ObjectInfo: Sendable {
    var key: String
    var size: Int64
    var lastModified: String
    var etag: String
}
