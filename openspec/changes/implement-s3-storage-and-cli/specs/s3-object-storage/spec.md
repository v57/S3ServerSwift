## ADDED Requirements

### Requirement: Client-observable S3 error and status mapping
The server SHALL produce the same HTTP status, S3 error code, and message as the reference for each rejectable condition: oversized declared or streamed bodies `413 EntityTooLarge`; non-limit body failures `500 InternalError`; invalid bucket/key encoding, bucket/key escape, and symlinked components `400 InvalidURI`; a missing or unconfigured bucket `404 NoSuchBucket`; a non-list request without a key `400 InvalidRequest`; an unsupported `list-type` `400 InvalidRequest`; a missing object for GET/HEAD/DELETE `404 NoSuchKey`; a PUT write or rename failure `500 InternalError`; and an authenticated unsupported method `405 MethodNotAllowed`.

#### Scenario: Error ordering before dispatch
- **WHEN** a request is oversized, unauthenticated, malformed in bucket/key, or targets an unsupported method
- **THEN** the server SHALL evaluate body limit, then authentication, then bucket/key parsing, then bucket/key and symlink validation, then method dispatch, returning the first applicable error without mutating storage

#### Scenario: XML error document
- **WHEN** any S3 error condition is reached
- **THEN** the response SHALL have `application/xml; charset=utf-8` content type, an escaped `Code` and `Message`, and a non-empty `RequestId`

## MODIFIED Requirements

### Requirement: Bucket addressing and root selection
The server SHALL support path-style and reference-compatible virtual-host-style bucket addressing, use an explicit normalized per-bucket root when configured, fall back to `<default-root>/<bucket>`, and reject an unconfigured bucket when no default root exists.

#### Scenario: Explicit and fallback roots
- **WHEN** requests target one explicitly mapped bucket and one unmapped bucket with a default root
- **THEN** each object SHALL be stored beneath the corresponding explicit or fallback root

#### Scenario: No available root
- **WHEN** a bucket is not mapped and the server has no default root
- **THEN** the server SHALL return `404 NoSuchBucket`

#### Scenario: Addressing styles
- **WHEN** equivalent signed requests identify a bucket through the first host label or the first path segment under the reference host-detection rules
- **THEN** both SHALL route to the same bucket and key

#### Scenario: Virtual-host detection rules
- **WHEN** the request host is `localhost`, ends in `.local`, is an IP literal, or has two or fewer dot-separated labels
- **THEN** the server SHALL treat it as path-style with no host-derived bucket, and a subdomain host's first label SHALL be the bucket

#### Scenario: Path-style bucket decode
- **WHEN** the first path segment is percent-encoded or contains a slash or backslash after decode
- **THEN** the server SHALL decode it as the bucket and SHALL return `400 InvalidURI` for invalid encodings or slash/backslash bucket names

#### Scenario: Conflicting host and path buckets
- **WHEN** both a host-derived bucket and a path-derived bucket are present and differ
- **THEN** the host-derived bucket SHALL win and the entire path SHALL be treated as the key

### Requirement: Safe filesystem path handling
The server SHALL normalize separators, percent-decode bucket/key components, reject invalid encodings and bucket names, contain resolved keys beneath the selected bucket root, and reject symlinks in existing bucket/object path components.

#### Scenario: Traversal attempt
- **WHEN** a decoded key or bucket resolution would escape its configured root
- **THEN** the server SHALL return an S3 `InvalidURI` error and SHALL not access the escaped path

#### Scenario: Symlink attempt
- **WHEN** the bucket root or an existing object path component is a symbolic link
- **THEN** the operation SHALL be rejected and SHALL not follow the link

#### Scenario: Backslash normalization
- **WHEN** a key contains backslash separators
- **THEN** the server SHALL treat them as forward slashes before resolving and containing the path

#### Scenario: Default-root escape
- **WHEN** bucket resolution under a default root would escape that root
- **THEN** the server SHALL return `400 InvalidURI` and SHALL not access the escaped path

### Requirement: PUT object
An authenticated `PUT` SHALL enforce the configured body limit, validate the payload before mutation, create parent directories, write through a unique sibling temporary file, atomically replace an existing object, clean up failures, and return `200` with the stored object's ETag.

#### Scenario: Create and overwrite
- **WHEN** clients PUT an object and then PUT different bytes to the same key
- **THEN** a subsequent GET SHALL return only the second complete body

#### Scenario: Oversized body
- **WHEN** declared or received bytes exceed a positive maximum body size
- **THEN** the server SHALL return `413 EntityTooLarge`, persist no partial object, and remove temporary data

#### Scenario: Atomic replacement and failure cleanup
- **WHEN** a PUT writes a unique sibling temporary file and the rename over the target fails
- **THEN** the server SHALL retry after removing the target or return `500 InternalError`, and in the failure case SHALL unlink the temporary file and preserve the prior object where possible

### Requirement: GET and HEAD object
Authenticated `GET` and `HEAD` requests for a regular stored object SHALL return consistent content length, last-modified time, quoted ETag, and appropriate content type; HEAD SHALL omit the body.

#### Scenario: Existing object metadata
- **WHEN** GET and HEAD target the same object
- **THEN** both SHALL return `200` and matching length, modification, and ETag metadata while only GET returns object bytes

#### Scenario: Missing object
- **WHEN** GET or HEAD targets a missing object
- **THEN** the server SHALL return `404 NoSuchKey`

#### Scenario: Content type fallback
- **WHEN** GET targets an object whose extension maps to a known MIME type or has no mapping
- **THEN** the server SHALL return the mapped content type or `application/octet-stream`, matching the reference derivation

### Requirement: DELETE object
An authenticated `DELETE` SHALL remove an existing object and return `204`, while a missing key SHALL produce the same `404 NoSuchKey` behavior as the reference.

#### Scenario: Delete lifecycle
- **WHEN** an existing object is deleted and then fetched
- **THEN** DELETE SHALL return `204` and the later GET SHALL return `404 NoSuchKey`

### Requirement: ListObjectsV2-compatible listing
An authenticated bucket GET SHALL recursively list regular files in deterministic lexical order and emit S3 XML with Name, Prefix, KeyCount, MaxKeys, IsTruncated, Contents metadata, optional Delimiter/CommonPrefixes, and ListObjectsV2 continuation elements.

#### Scenario: Prefix and delimiter
- **WHEN** listing uses a prefix and delimiter
- **THEN** direct matching objects SHALL appear in Contents, deeper groups SHALL appear once in sorted CommonPrefixes, and KeyCount SHALL include both

#### Scenario: Maximum and continuation
- **WHEN** more matching objects exist than the positive `max-keys` value and a subsequent request supplies the returned continuation token with `list-type=2`
- **THEN** the first result SHALL be truncated with a next token and the next result SHALL resume after that key without duplication

#### Scenario: List defaults and validation
- **WHEN** `max-keys` is missing/non-positive or above 1000, or `list-type` has an unsupported value
- **THEN** the effective maximum SHALL match the reference default/cap and unsupported list types SHALL return `400 InvalidRequest`

#### Scenario: Regular files only
- **WHEN** the bucket root contains directories or non-regular files alongside objects
- **THEN** the listing SHALL include only regular files as Contents and SHALL not follow symlinked directories

### Requirement: Metadata parity
The server SHALL generate ISO-8601 list timestamps, RFC-compatible Last-Modified headers, and quoted MD5 ETags from the same size and modification-time-millisecond formula as the Bun server.

#### Scenario: Metadata consistency
- **WHEN** one object is observed through PUT, GET, HEAD, and LIST
- **THEN** ETag and size SHALL be mutually consistent and all timestamps SHALL represent the stored file modification time

#### Scenario: ETag and millisecond formula
- **WHEN** an ETag is computed for a stored object
- **THEN** it SHALL be the quoted lowercase MD5 hex of `"<size>:<mtimeMilliseconds>"` using the same millisecond truncation as the reference, shared by PUT, GET, HEAD, and LIST
