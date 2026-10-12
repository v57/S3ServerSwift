## Context

`port-s3-server-to-swift` delivered the Swift server foundation: `S3ServerOptions`, the `S3Server` actor with `NWListener`/`HTTPConnection` transport, `HTTPRequestParser`/`HTTPResponseWriter`, and the full SigV4 verifier with golden tests. It stops the moment a request is authenticated: `S3Server.swift` returns `501 S3 request handling is not implemented`, the `Server` target is a stub, and `S3/`, `Storage/`, and `CLI/` are placeholder files.

This change fills the gap (tasks §7–§11) so the Swift `Server` is interchangeable with the Bun reference for every operation the contract suite exercises. The Bun implementation (`index.ts`, `server.ts`) remains the compatibility oracle; the shared TypeScript suite already exists as a backend-neutral harness from `port-s3-server-to-swift` task §2.

## Goals / Non-Goals

**Goals**

- Make every authenticated request that the Bun server handles produce the same status, headers, S3 code/message, and XML/bytes.
- Keep the dependency-free constraint: Foundation, Network, CryptoKit, Darwin only; no change to `Package.swift` dependencies.
- Preserve the existing separation (transport → auth → routing → storage) and Swift 6 concurrency safety.
- Land in vertical slices, each enabling its matching contract/unit tests before moving on.

**Non-Goals**

- Anything outside `index.ts`/`server.ts`: multipart upload, ranged GET, versioning, ACLs, bucket create/delete, TLS, persistence internals.
- Keep-alive/pipelining (the current HTTP runtime closes after one request).
- Linux support.
- Changing the Bun reference behavior; if the reference and this design disagree, the reference wins and this design is fixed.

## Decisions

### 1. Route through `BucketRouter` and `ObjectStore`, not inline in the handler

Replace the `501` closure in `S3Server.accept` with an `S3RequestHandler` (or a method on `S3Server`) that dispatches to a `BucketRouter` (bucket detection + root resolution + key decode/normalize) and an `ObjectStore` (PUT/GET/HEAD/DELETE/LIST, path containment, symlink checks, ETags, listing).

Alternative considered: translate `index.ts` inline into the handler closure. Rejected — routing, filesystem safety, and listing each need focused unit tests without spinning up a listener, and Swift 6 wants clear ownership of the filesystem calls.

### 2. Bucket detection reproduces `parseBucketFromHost` + `parseBucketAndKey` exactly

Virtual-host bucket detection uses the hostname with these rules, lifted from `index.ts`:

- `localhost`, any `.local` suffix, and any IP literal → no host bucket (path-style only).
- Hosts with ≤ 2 dot-separated labels → no host bucket (e.g. `machine.lan`).
- Otherwise the bucket is the first label.

Path-style parsing splits the pathname on `/`, filters empty segments, percent-decodes the first segment as the bucket (invalid encoding → `400 InvalidURI`). When both a host bucket and path bucket exist and differ, the host bucket wins and the entire path becomes the key (matching `index.ts`). A bucket that is empty after trim → `404 NoSuchBucket`; a bucket containing `/` or `\` → `400 InvalidURI`.

### 3. Path resolution is containment + per-component `lstat`

Root selection: explicit normalized `bucketPaths[bucket]` if present, else `<defaultRoot>/<bucket>` if a default root exists, else `404 NoSuchBucket`. The default-root fallback also checks `<resolved> == root || resolved.hasPrefix(root + separator)` and returns `400 InvalidURI` on escape (mirroring `resolveBucketPath`'s guard).

Object resolution joins the backslash-normalized key to the bucket root, then requires `resolved == bucketRoot || resolved.hasPrefix(bucketRoot + separator)`, else `400 InvalidURI` (`key escapes bucket directory`).

Symlink rejection walks the relative path component by component with `lstat`: reject if the bucket root itself is a symlink (`bucket path is a symlink`) or any existing component is a symlink (`symlink not allowed in object path`). Non-existent components are allowed (PUT creates them). This matches `assertNoSymlinkInPath`; we re-check immediately before mutation.

Alternative considered: string-prefix checks alone. Rejected — they miss symlink escapes, which the contract suite probes with sentinel files.

### 4. PUT is parent-create → unique sibling temp → atomic rename, with cleanup

`normalizeKey` replaces `\` with `/`. PUT: `mkdir -p` the parent, write to `<path>.upload-<uuid>`, `rename` over the target (on failure unlink the target and retry once, as `index.ts` does), return `200` with `ETag` computed from the post-rename `stat`. On any write/rename failure, unlink the temp file and return `500 InternalError`; the prior object is preserved wherever the rename retry path allows. `Content-Length` over the limit is rejected `413 EntityTooLarge` before the body is fully consumed; streamed byte-count over the limit raises `413` mid-read.

### 5. One ETag, MIME, and date formula shared by PUT/GET/HEAD/LIST

- ETag: `"\(md5Hex("\(size):\(mtimeMilliseconds)))"` where `mtimeMilliseconds` is the file mtime in milliseconds. Reproduce Bun's `Date.now`/`stats.mtimeMs` truncation precisely (Bun truncates toward zero with millisecond precision); define one helper used everywhere so ETag is consistent across operations on the same file.
- GET `Content-Type`: system-derived MIME (Foundation `NSURL`/UTI or the Bun `file.type` equivalent) with `application/octet-stream` fallback.
- `Last-Modified`: `mtime.toUTCString()` equivalent — `Date` formatted as RFC 1123 in fixed en-US_POSIX/UTC.
- LIST `LastModified`: `mtime.toISOString()` equivalent — fixed-locale UTC ISO-8601 with milliseconds.

### 6. ListObjectsV2 enumeration order, prefix/delimiter, pagination

Recursive walk of the bucket root, sorting each directory's entries with a stable lexical `localeCompare`-equivalent. Directories are not results; only regular files become `Contents`. For each entry: compute the POSIX key; if a prefix is set, skip keys not starting with it; apply delimiter grouping (if the segment after the prefix contains the delimiter, add the grouped common prefix and don't descend); apply continuation-token resume (skip keys `<= token` until past it, then include). Stop when `results.length >= maxKeys` and set `IsTruncated` + `NextContinuationToken` (last returned key) under `list-type=2`. `KeyCount = objects.count + commonPrefixes.count`. `max-keys`: missing/non-positive/above 1000 → 1000. Unsupported `list-type` → `400 InvalidRequest`. XML is `ListBucketResult` with all five reserved characters escaped; `ContinuationToken`/`NextContinuationToken` only under `list-type=2`.

### 7. Canonical error/status table (single source)

| Condition | Status | S3 code | Message |
|---|---|---|---|
| Auth fail (any) | 403 | `AccessDenied` / `RequestTimeTooSkewed` | (from verifier) |
| Declared/streamed body over limit | 413 | `EntityTooLarge` | `Payload too large` |
| Body read failure (non-limit) | 500 | `InternalError` | underlying message |
| Invalid bucket/key encoding; escape; symlink | 400 | `InvalidURI` | specific message |
| Bucket not specified/configured | 404 | `NoSuchBucket` | `Bucket not specified` / `Bucket not configured` |
| Non-list op, no key | 400 | `InvalidRequest` | `Key is required` |
| Unsupported `list-type` | 400 | `InvalidRequest` | `Unsupported list type` |
| GET/HEAD/DELETE missing object | 404 | `NoSuchKey` | `Object not found` |
| PUT write/rename failure | 500 | `InternalError` | underlying message |
| Authenticated unsupported method | 405 | `MethodNotAllowed` | `Unsupported method` |

All error responses are XML (`application/xml; charset=utf-8`) with escaped `Code`/`Message` and a non-empty `RequestId` (UUID). Order of checks matches `index.ts`: body limit → auth → bucket/key parse → bucket/key validation → symlink → method dispatch.

### 8. `ServerOptionsParser` is injectable and reproduces `parseServerOptions`

A pure `enum ServerOptionsParser` (already stubbed) with `parse(_ argv: [String], environment: [String: String]) -> ParsedServerArgs` so unit tests need no process-env mutation. Reproduce:

- Flags: `--help`/`-h`, `--host`, `--port`, `--path`, `--key`, `--secret`, `--session-token`, `--max-body-bytes`, `--max-time-skew-seconds`, repeatable `--bucket-path bucket=path`; one positional path (`--path` wins; else positional; else `S3_DATA_DIR`; else `.`).
- Precedence: argument → `S3_*` → `AWS_*` → default; credentials default to generated 16-byte lowercase hex; integers use JS `parseInt` prefix semantics (parse leading decimal, `NaN` → fallback); port default `9000`, body/skew default `0`.
- Errors: unknown flag, missing value, malformed `bucket=path` (`separatorIndex <= 0` or at end), extra positional → useful message + nonzero exit, no listener.
- Help: the `buildServerHelpText` content, exit 0, no root creation / no listener.

`main` wires `CommandLine.arguments`/`ProcessInfo.processInfo.environment` through it, prints credentials/dir/buckets/listening URL, runs until `SIGINT`/`SIGTERM`, then `server.stop()` and exit.

### 9. Swift 6 concurrency and Sendable ownership

`BucketRouter` and `ObjectStore` take immutable `S3ServerOptions` (already `Sendable`) and are value types or actors as natural to the call path; filesystem work runs off the listener callback via the existing `Task` per connection. No new shared mutable state. Tests keep using ephemeral ports and temp dirs.

## Risks / Trade-offs

- **Bun `mtimeMs`/`parseInt` semantics differ from Foundation's.** → Pin both with focused unit tests against controlled fixture mtimes and known integer strings; define millisecond truncation explicitly before coding.
- **Symlink TOCTOU between `lstat` and write.** → Re-check immediately before mutation, use sibling temp + atomic rename, and document the trusted-local-host threat model (already a non-goal of the reference).
- **MIME derivation differs from Bun `file.type`.** → Assert extension→MIME cases used by the suite; fall back to `application/octet-stream` everywhere else, matching the reference.
- **Virtual-host edge cases (`.local`, IP, two-label).** → Cover each explicitly in `BucketRouter` unit tests.
- **Help text drift.** → Assert the option list and key examples rather than exact bytes where the reference is invocation-prefixed.

## Migration Plan

1. Implement routing + path safety + error table (§7, plus the error/status requirement) and the focused Swift unit tests; the handler still 501s for actual ops but bucket/key/escape/symlink cases now return correct errors.
2. Implement PUT/GET/HEAD/DELETE (§8) and enable the corresponding contract cases.
3. Implement ListObjectsV2 (§9) and enable pagination/delimiter contract cases.
4. Implement `ServerOptionsParser` + `main` (§10) and enable CLI process tests.
5. Run `swift test`, the Bun reference suite, and the Swift contract suite; format and `openspec validate --strict` (§11).
6. Keep Bun as the default executable until the Swift contract suite is fully green; no storage-format migration means rollback is selecting Bun.

## Open Questions

- Confirm the exact MIME mapping strategy that best matches Bun's `file.type` for the extensions the suite checks (Foundation UTI is the default; flag any extension where it diverges).
- Decide whether `NextContinuationToken` shape should be opaque or the raw last key — the reference uses the raw last key, so this design assumes raw key; revisit only if a contract case disagrees.
