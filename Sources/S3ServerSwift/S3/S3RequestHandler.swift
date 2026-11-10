import Foundation

/// Authenticated S3 request dispatch, mirroring the reference `fetch` body:
/// parse bucket/key → resolve → validate → dispatch to storage.
///
/// The server checks a request's signature from its head, then `admit` decides
/// from the head alone what to do with its body: an upload streams to a
/// temporary file next to its object, other requests' (small) bodies are read
/// into memory, and anything refused is answered before a body byte is read.
struct S3RequestHandler: Sendable {
    let store: ObjectStore
    let hooks: S3ServerHooks
    /// 0: no limit
    let maximumBodyBytes: Int
    /// Bodies of requests other than uploads are read into memory; S3 needs none
    static let maximumBufferedBodyBytes = 1 << 20

    init(options: S3ServerOptions, hooks: S3ServerHooks = S3ServerHooks()) {
        self.store = ObjectStore(
            router: BucketRouter(
                bucketPaths: options.bucketPaths,
                defaultRoot: options.path
            )
        )
        self.hooks = hooks
        maximumBodyBytes = options.maximumBodyBytes
    }

    /// What to do with a request whose signature passed, before its body is read
    func admit(_ head: HTTPRequestHead, payload: SigV4Payload) -> HTTPAdmission {
        if maximumBodyBytes > 0, head.contentLength > maximumBodyBytes {
            return .respond(S3Responses.xmlError(.entityTooLarge))
        }
        guard head.method == "PUT" else {
            guard head.contentLength <= Self.maximumBufferedBodyBytes else {
                return .respond(S3Responses.xmlError(.entityTooLarge))
            }
            return .buffer { body in
                guard payload.matches(body) else {
                    return S3Responses.xmlError(.accessDenied("payload hash mismatch"))
                }
                return handle(HTTPRequest(head: head, body: body))
            }
        }

        let upload: ObjectStore.PendingUpload
        do {
            let (bucket, key) = try route(head.target)
            upload = try store.prepareUpload(bucket: bucket, key: key)
        } catch {
            return .respond(Self.response(for: error))
        }
        let request = S3Upload(
            bucket: upload.bucket,
            key: upload.key,
            length: Int64(head.contentLength),
            replacedSize: upload.replacedSize
        )
        if let refusal = hooks.admitUpload?(request) {
            return .respond(S3Responses.xmlError(refusal))
        }
        let ended = hooks.uploadEnded.map { ended in { @Sendable in ended(request) } }
        do {
            return .stream(try UploadSink(store: store, upload: upload, payload: payload, changed: hooks.changed, ended: ended))
        } catch {
            ended?()
            return .respond(Self.response(for: error))
        }
    }

    /// A request with its body in memory
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let target = request.target
        let path = RequestQuery.path(in: target)

        let bucket: String?
        let key: String?
        do {
            (bucket, key) = try store.router.bucketAndKey(path: path)
        } catch {
            return Self.response(for: error)
        }

        guard let bucket else {
            return S3Responses.xmlError(.bucketNotSpecified)
        }

        if key == nil && request.method == "GET" {
            return handleList(bucket: bucket, target: target)
        }
        guard let key else {
            return S3Responses.xmlError(.keyRequired)
        }

        do {
            switch request.method {
            case "PUT":
                let response = try store.put(bucket: bucket, key: key, body: request.body)
                return response
            case "HEAD":
                return try store.head(bucket: bucket, key: key)
            case "GET":
                return try store.get(bucket: bucket, key: key, range: RequestQuery.headerValue("range", in: request.headers))
            case "DELETE":
                let size = try store.deleteObject(bucket: bucket, key: key)
                hooks.changed?(.deleted(bucket: bucket, key: key, size: size))
                return HTTPResponse(status: 204)
            default:
                return S3Responses.xmlError(.methodNotAllowed)
            }
        } catch {
            return Self.response(for: error)
        }
    }

    /// The bucket and key a request target names; both are required
    private func route(_ target: String) throws -> (bucket: String, key: String) {
        let (bucket, key) = try store.router.bucketAndKey(path: RequestQuery.path(in: target))
        guard let bucket else { throw S3Error.bucketNotSpecified }
        guard let key else { throw S3Error.keyRequired }
        return (bucket, key)
    }

    static func response(for error: Error) -> HTTPResponse {
        switch error {
        case let error as S3Error: S3Responses.xmlError(error)
        case let error as CanonicalizationError: S3Responses.xmlError(.invalidURI("\(error)"))
        default: S3Responses.xmlError(.internalError(error.localizedDescription))
        }
    }

    private func handleList(bucket: String, target: String) -> HTTPResponse {
        let listType = RequestQuery.value("list-type", in: target)
        if let listType, listType != "2" {
            return S3Responses.xmlError(.unsupportedListType)
        }

        let prefix = RequestQuery.value("prefix", in: target)
        let delimiter = RequestQuery.value("delimiter", in: target)
        let maxKeys = parseMaxKeys(RequestQuery.value("max-keys", in: target))
        let continuationToken = listType == "2"
            ? RequestQuery.value("continuation-token", in: target)
            : nil

        let result: ObjectStore.ListResult
        do {
            result = try store.list(
                bucket: bucket,
                prefix: prefix,
                maxKeys: maxKeys,
                continuationToken: continuationToken,
                delimiter: delimiter
            )
        } catch let error as S3Error {
            return S3Responses.xmlError(error)
        } catch {
            return S3Responses.xmlError(.internalError(error.localizedDescription))
        }

        return ListObjectsXml.response(
            bucket: bucket,
            prefix: prefix,
            delimiter: delimiter,
            objects: result.objects,
            commonPrefixes: result.commonPrefixes,
            maxKeys: maxKeys,
            isTruncated: result.isTruncated,
            continuationToken: continuationToken,
            nextToken: result.nextToken,
            listType: listType
        )
    }

    /// Reference `max-keys`: missing/non-positive/above 1000 → 1000.
    private func parseMaxKeys(_ raw: String?) -> Int {
        guard let raw else { return 1000 }
        guard let value = parseIntPrefix(raw), value > 0 else { return 1000 }
        return min(value, 1000)
    }

    /// JavaScript `parseInt` prefix semantics: leading sign + decimal digits.
    private func parseIntPrefix(_ value: String) -> Int? {
        let trimmed = value.drop(while: \.isWhitespace)
        let sign: String
        let digitsStart: Substring.Index
        if let first = trimmed.first, (first == "-" || first == "+") {
            sign = String(first)
            digitsStart = trimmed.index(after: trimmed.startIndex)
        } else {
            sign = ""
            digitsStart = trimmed.startIndex
        }
        let digits = trimmed[digitsStart...].prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(sign + digits)
    }
}

/// An upload's body on its way to the temporary file next to its object, hashed
/// while it comes when the signature covers its hash. `finish` checks the hash
/// and renames the file over the object; anything else removes it.
final class UploadSink: HTTPBodySink, @unchecked Sendable {
    private let store: ObjectStore
    private let upload: ObjectStore.PendingUpload
    private let payload: SigV4Payload
    private let changed: (@Sendable (S3Change) -> Void)?
    private let ended: (@Sendable () -> Void)?
    private let handle: FileHandle
    private var hasher: SHA256Hasher?
    private var isDone = false

    init(
        store: ObjectStore,
        upload: ObjectStore.PendingUpload,
        payload: SigV4Payload,
        changed: (@Sendable (S3Change) -> Void)?,
        ended: (@Sendable () -> Void)? = nil
    ) throws {
        self.store = store
        self.upload = upload
        self.payload = payload
        self.changed = changed
        self.ended = ended
        guard FileManager.default.createFile(atPath: upload.tempPath, contents: nil) else {
            throw S3Error.internalError("Can't create the upload's file")
        }
        do {
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: upload.tempPath))
        } catch {
            store.discard(upload)
            throw S3Error.internalError(error.localizedDescription)
        }
        if payload != .unsigned { hasher = SHA256Hasher() }
    }

    func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            cancel()
            let code = (error as NSError).code
            if code == NSFileWriteOutOfSpaceError || code == Int(ENOSPC) {
                throw S3Error.storageFull("No space left on the device")
            }
            throw S3Error.internalError(error.localizedDescription)
        }
        hasher?.update(data)
    }

    func finish() -> HTTPResponse {
        guard !isDone else { return S3Responses.xmlError(.internalError("Upload already finished")) }
        isDone = true
        defer { ended?() }
        try? handle.close()
        if let hasher, !payload.matches(hex: hasher.finalizeHex()) {
            store.discard(upload)
            return S3Responses.xmlError(.accessDenied("payload hash mismatch"))
        }
        do {
            let (response, size) = try store.commit(upload)
            changed?(.stored(bucket: upload.bucket, key: upload.key, size: size, replacedSize: upload.replacedSize))
            return response
        } catch {
            return S3RequestHandler.response(for: error)
        }
    }

    func cancel() {
        guard !isDone else { return }
        isDone = true
        try? handle.close()
        store.discard(upload)
        ended?()
    }

    func failure(_ error: Error) -> HTTPResponse {
        S3RequestHandler.response(for: error)
    }
}
