## Why

The `port-s3-server-to-swift` change landed the Swift server foundation — configuration, the Network.framework HTTP/1.1 runtime, and full SigV4 verification — and validated cleanly, but stopped at task §6. Today `S3Server` returns `501 S3 request handling is not implemented` for every authenticated request, the `Server` executable prints `Server implementation is not complete.` and exits, and bucket routing, object operations, and `ListObjectsV2` are entirely absent. This change implements the remaining S3 behavior (tasks §7–§11) so the Swift server is a real, interchangeable replacement for the Bun reference.

## What Changes

- Implement bucket and key resolution: path-style and reference virtual-host bucket detection, explicit per-bucket roots, default-root fallback, percent-decode/validate bucket and key components, backslash normalization, and `404 NoSuchBucket` for unmapped buckets.
- Implement containment-safe path resolution plus component-by-component `lstat` symlink rejection for bucket roots and existing object paths, returning `400 InvalidURI` on any escape or symlink.
- Implement authenticated object operations: `PUT` (parent creation, unique sibling temp file, atomic replace, failure cleanup, `200` + quoted ETag, `413 EntityTooLarge` for oversized declared/streamed bodies), `GET` (regular-file bytes, content length, last-modified, ETag, system-derived MIME with `application/octet-stream` fallback), `HEAD` (GET-equivalent metadata, no body), and `DELETE` (`204` existing, `404 NoSuchKey` missing).
- Implement `ListObjectsV2`/`ListObjects`: deterministic recursive lexical enumeration of regular files, prefix pruning, delimiter grouping into sorted unique common prefixes, `max-keys` parse/default/cap at 1000, truncation and `list-type=2` continuation-token resume, `400 InvalidRequest` for unsupported list types, and the full `ListBucketResult` XML with escaped fields.
- Implement the canonical error/status table and S3 XML error documents with non-empty request IDs, generated from one shared path so PUT/GET/HEAD/DELETE/LIST/errors all match.
- Implement MD5 ETags from the exact `MD5("\(size):\(mtimeMilliseconds)")` formula with the Bun `mtimeMs` truncation rule, and ISO-8601 list timestamps / RFC Last-Modified headers shared across all operations.
- Implement the `Server` executable: an injectable `ServerOptionsParser` over argv and environment reproducing the reference flag set, positional path, repeatable `--bucket-path`, argument-over-`S3`/`AWS`/default precedence, JavaScript `parseInt` integer semantics, generated 16-byte lowercase-hex credentials, help text with zero exit and no listener, startup logging, and clean `SIGINT`/`SIGTERM` shutdown.
- Wire dispatch through SigV4 so unauthenticated requests never reach storage and authenticated unsupported methods return `405 MethodNotAllowed`.

## Capabilities

### New Capabilities

None. All affected requirements already exist in the `port-s3-server-to-swift` change; this change tightens them with implementation-acceptance detail and scenarios.

### Modified Capabilities

- `s3-object-storage`: bucket/key resolution, safe path handling, PUT, GET/HEAD, DELETE, ListObjectsV2, and metadata-parity requirements gain implementation-acceptance scenarios; a new requirement pins the client-observable error/status table.
- `server-cli`: argument, environment/precedence, defaults/credentials, and help/startup requirements gain executable-process acceptance scenarios.
- `swift-s3-server`: the S3 XML/response-compatibility requirement gains the concrete error/status mappings it currently only describes generically.

## Impact

- `Sources/S3ServerSwift/S3/`, `Storage/`, and `CLI/` grow from placeholders into the routing, storage, listing, and parser implementations; `Sources/S3ServerSwift/HTTP/S3Server.swift` replaces the `501` stub handler with real dispatch and gains a `BucketRouter`/`ObjectStore` seam.
- `Sources/Server/main.swift` is replaced with a real entrypoint built on `ServerOptionsParser` and `S3Server`, including signal handling.
- `Tests/S3ServerSwiftTests/` adds focused unit tests for routing, path containment, listing, XML, ETags, and CLI parsing under the existing empty module directories.
- The shared TypeScript contract suite gains matching cases for HEAD, empty/binary content, body limits, listing pagination, traversal/symlinks, unsupported methods, error XML, and CLI process behavior.
- No change to `Package.swift` products/dependencies; the dependency-free constraint is preserved. Bun remains the default and the compatibility oracle.
