import Foundation

/// Authenticated S3 request dispatch, mirroring the reference `fetch` body:
/// parse bucket/key → resolve → validate → dispatch to storage.
///
/// Body-limit enforcement runs in the transport/parser before authentication,
/// matching the reference ordering; this handler assumes an authenticated
/// request and never touches storage for unauthenticated ones.
struct S3RequestHandler: Sendable {
    let store: ObjectStore

    init(options: S3ServerOptions) {
        self.store = ObjectStore(
            router: BucketRouter(
                bucketPaths: options.bucketPaths,
                defaultRoot: options.path
            )
        )
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let target = request.target
        let host = RequestQuery.hostname(from: request.headers)
        let path = RequestQuery.path(in: target)

        let bucket: String?
        let key: String?
        do {
            (bucket, key) = try store.router.bucketAndKey(host: host, path: path)
        } catch let error as S3Error {
            return S3Responses.xmlError(error)
        } catch {
            return S3Responses.xmlError(.invalidURI(error.localizedDescription))
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
                return try store.put(bucket: bucket, key: key, body: request.body)
            case "HEAD":
                return try store.head(bucket: bucket, key: key)
            case "GET":
                return try store.get(bucket: bucket, key: key)
            case "DELETE":
                return try store.delete(bucket: bucket, key: key)
            default:
                return S3Responses.xmlError(.methodNotAllowed)
            }
        } catch let error as S3Error {
            return S3Responses.xmlError(error)
        } catch {
            return S3Responses.xmlError(.internalError(error.localizedDescription))
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
