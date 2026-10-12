import Foundation

/// Serializes ListObjectsV2/ListObjects XML matching the reference `listXml`.
enum ListObjectsXml {
    static func response(
        bucket: String,
        prefix: String?,
        delimiter: String?,
        objects: [ObjectInfo],
        commonPrefixes: [String],
        maxKeys: Int,
        isTruncated: Bool,
        continuationToken: String?,
        nextToken: String?,
        listType: String?
    ) -> HTTPResponse {
        var contents = ""
        for obj in objects {
            contents += "\n  <Contents>"
            contents += "\n    <Key>\(S3Responses.xmlEscape(obj.key))</Key>"
            contents += "\n    <LastModified>\(S3Responses.xmlEscape(obj.lastModified))</LastModified>"
            contents += "\n    <ETag>\(S3Responses.xmlEscape(obj.etag))</ETag>"
            contents += "\n    <Size>\(obj.size)</Size>"
            contents += "\n    <StorageClass>STANDARD</StorageClass>"
            contents += "\n  </Contents>"
        }

        var prefixesXml = ""
        for prefix in commonPrefixes {
            prefixesXml += "\n  <CommonPrefixes>"
            prefixesXml += "\n    <Prefix>\(S3Responses.xmlEscape(prefix))</Prefix>"
            prefixesXml += "\n  </CommonPrefixes>"
        }

        var delimiterXml = ""
        if let delimiter {
            delimiterXml = "\n  <Delimiter>\(S3Responses.xmlEscape(delimiter))</Delimiter>"
        }

        var continuationXml = ""
        if listType == "2", let continuationToken, !continuationToken.isEmpty {
            continuationXml = "\n  <ContinuationToken>\(S3Responses.xmlEscape(continuationToken))</ContinuationToken>"
        }

        var nextTokenXml = ""
        if listType == "2", isTruncated, let nextToken, !nextToken.isEmpty {
            nextTokenXml = "\n  <NextContinuationToken>\(S3Responses.xmlEscape(nextToken))</NextContinuationToken>"
        }

        let body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "\n<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
            + "\n  <Name>\(S3Responses.xmlEscape(bucket))</Name>"
            + "\n  <Prefix>\(S3Responses.xmlEscape(prefix ?? ""))</Prefix>"
            + "\n  <KeyCount>\(objects.count + commonPrefixes.count)</KeyCount>"
            + "\n  <MaxKeys>\(maxKeys)</MaxKeys>"
            + "\n  <IsTruncated>\(isTruncated ? "true" : "false")</IsTruncated>"
            + delimiterXml + continuationXml + nextTokenXml + contents + prefixesXml
            + "\n</ListBucketResult>"

        return HTTPResponse(
            status: 200,
            headers: ["content-type": "application/xml; charset=utf-8"],
            body: Data(body.utf8)
        )
    }
}
