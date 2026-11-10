import Foundation

/// An S3 error answer: its XML `Code` and `Message` and the HTTP status
public struct S3Error: Error, Sendable, Equatable {
    public var code: String
    public var message: String
    public var status: Int

    public init(code: String, message: String, status: Int) {
        self.code = code
        self.message = message
        self.status = status
    }

    /// 507 for an upload the storage has no room for
    public static func storageFull(_ message: String = "Not enough storage for this object") -> S3Error {
        S3Error(code: "StorageFull", message: message, status: 507)
    }
}

/// An authenticated upload, before its body is read
public struct S3Upload: Sendable, Equatable {
    public var bucket: String
    public var key: String
    /// The body's length (`Content-Length`)
    public var length: Int64
    /// The size of the object it replaces, 0 for a new one
    public var replacedSize: Int64

    public init(bucket: String, key: String, length: Int64, replacedSize: Int64) {
        self.bucket = bucket
        self.key = key
        self.length = length
        self.replacedSize = replacedSize
    }
}

/// What changed in the storage through the server
public enum S3Change: Sendable, Equatable {
    /// An object stored, `size` bytes, over one of `replacedSize` (0 for a new one)
    case stored(bucket: String, key: String, size: Int64, replacedSize: Int64)
    /// An object deleted, freeing `size` bytes
    case deleted(bucket: String, key: String, size: Int64)
}

/// Where an app embedding the server steps in
public struct S3ServerHooks: Sendable {
    /// Whether to answer a connection from this address (`127.0.0.1`, `::1`, `100.96.0.3`; IPv4-mapped IPv6
    /// addresses come as IPv4). Refused connections close without an answer. nil answers every address.
    public var acceptsConnection: (@Sendable (String) -> Bool)?
    /// After an upload's signature passed and before its body is read: an error refuses it (a quota's
    /// `S3Error.storageFull`), nil lets it in
    public var admitUpload: (@Sendable (S3Upload) -> S3Error?)?
    /// After an object was stored or deleted through the server
    public var changed: (@Sendable (S3Change) -> Void)?
    /// Once for every upload `admitUpload` let in, when it ended: stored (after `changed`), refused for its hash,
    /// failed or cut off. A quota holds the upload's room from admission until then, so uploads that run at the
    /// same time can't fill more than it allows together.
    public var uploadEnded: (@Sendable (S3Upload) -> Void)?

    public init(
        acceptsConnection: (@Sendable (String) -> Bool)? = nil,
        admitUpload: (@Sendable (S3Upload) -> S3Error?)? = nil,
        changed: (@Sendable (S3Change) -> Void)? = nil,
        uploadEnded: (@Sendable (S3Upload) -> Void)? = nil
    ) {
        self.acceptsConnection = acceptsConnection
        self.admitUpload = admitUpload
        self.changed = changed
        self.uploadEnded = uploadEnded
    }
}
