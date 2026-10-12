## ADDED Requirements

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

### Requirement: Safe filesystem path handling
The server SHALL normalize separators, percent-decode bucket/key components, reject invalid encodings and bucket names, contain resolved keys beneath the selected bucket root, and reject symlinks in existing bucket/object path components.

#### Scenario: Traversal attempt
- **WHEN** a decoded key or bucket resolution would escape its configured root
- **THEN** the server SHALL return an S3 `InvalidURI` error and SHALL not access the escaped path

#### Scenario: Symlink attempt
- **WHEN** the bucket root or an existing object path component is a symbolic link
- **THEN** the operation SHALL be rejected and SHALL not follow the link

### Requirement: Home and relative path normalization
Configured roots SHALL expand `~` and `~/` using `HOME`, resolve relative paths against the launch working directory, and fail clearly when home expansion is requested without `HOME`.

#### Scenario: Tilde roots
- **WHEN** default and per-bucket roots begin with `~/`
- **THEN** server startup SHALL create and use the corresponding paths beneath `HOME`

### Requirement: PUT object
An authenticated `PUT` SHALL enforce the configured body limit, validate the payload before mutation, create parent directories, write through a unique sibling temporary file, atomically replace an existing object, clean up failures, and return `200` with the stored object's ETag.

#### Scenario: Create and overwrite
- **WHEN** clients PUT an object and then PUT different bytes to the same key
- **THEN** a subsequent GET SHALL return only the second complete body

#### Scenario: Oversized body
- **WHEN** declared or received bytes exceed a positive maximum body size
- **THEN** the server SHALL return `413 EntityTooLarge`, persist no partial object, and remove temporary data

### Requirement: GET and HEAD object
Authenticated `GET` and `HEAD` requests for a regular stored object SHALL return consistent content length, last-modified time, quoted ETag, and appropriate content type; HEAD SHALL omit the body.

#### Scenario: Existing object metadata
- **WHEN** GET and HEAD target the same object
- **THEN** both SHALL return `200` and matching length, modification, and ETag metadata while only GET returns object bytes

#### Scenario: Missing object
- **WHEN** GET or HEAD targets a missing object
- **THEN** the server SHALL return `404 NoSuchKey`

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

### Requirement: Metadata parity
The server SHALL generate ISO-8601 list timestamps, RFC-compatible Last-Modified headers, and quoted MD5 ETags from the same size and modification-time-millisecond formula as the Bun server.

#### Scenario: Metadata consistency
- **WHEN** one object is observed through PUT, GET, HEAD, and LIST
- **THEN** ETag and size SHALL be mutually consistent and all timestamps SHALL represent the stored file modification time
