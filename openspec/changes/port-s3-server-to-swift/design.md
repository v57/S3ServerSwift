## Context

The repository has a single-file Bun library (`index.ts`), a Bun CLI (`server.ts`), Bun unit/integration tests, and a generated but empty Swift package. The Swift implementation must be an interchangeable process-level server for the existing Bun `S3Client` tests and must not add Swift Package Manager dependencies.

The reference behavior includes details not obvious from the advertised five S3 operations: HTTP/1.1 serving, SigV4 canonicalization and HMAC derivation, presigned URLs, virtual-host addressing, bounded request bodies, XML errors/listings, filesystem containment and symlink checks, atomic replacement, generated ETags, per-bucket paths, and CLI/environment precedence.

The no-dependency constraint makes the HTTP runtime the main architectural constraint. Foundation supplies data, URL, dates, files, process environment, and XML-safe string handling; Network supplies TCP serving; CryptoKit supplies SHA-256, HMAC-SHA256, constant-time authentication primitives, and MD5 through its insecure compatibility API. These are system frameworks on the supported Apple platforms.

## Goals / Non-Goals

**Goals:**

- Match every externally observable behavior implemented by the current Bun library and CLI.
- Expose a reusable Swift library API with explicit configuration and lifecycle control.
- Produce a `Server` executable that is launchable by the Bun test harness.
- Use no third-party Swift packages and keep `Package.swift` dependency-free.
- Make the TypeScript suite the cross-runtime source of truth, supplemented by focused Swift unit tests.
- Keep request parsing, auth, routing, and storage separated enough to test deterministically.

**Non-Goals:**

- Full AWS S3 coverage beyond the operations and options implemented by `index.ts`.
- Multipart upload, range requests, versioning, ACLs, bucket creation/deletion, TLS termination, or AWS-compatible persistence internals.
- Wire compatibility with HTTP/2 or HTTP/3.
- Replacing or deleting the Bun implementation.
- Linux support in the first implementation; using Network and CryptoKit defines an Apple-platform implementation unless an equivalent system-only adapter is separately added.
- Preserving internal Bun implementation structure, debug timing output, or exact random request IDs.

## Decisions

### 1. Treat the Bun implementation and contract tests as the compatibility oracle

Before porting, convert server startup in the integration suite into a harness selected by environment (for example, `S3_TEST_SERVER=bun|swift` and `S3_SWIFT_SERVER_BIN=<path>`). The same assertions run unchanged against both backends; only lifecycle ownership differs.

The Bun backend remains a regression baseline. The Swift backend is built before the suite, receives isolated ports/directories/credentials, waits on a readiness probe, captures logs, and is terminated reliably after tests. CLI parser tests remain Bun unit tests and equivalent Swift parser tests are added because importing Swift into Bun is not practical.

Alternative considered: duplicate the suite for Swift. Rejected because duplicated assertions drift and weaken the claim of compatibility.

### 2. Split the Swift library by protocol boundary

The library will contain these internal components:

- `S3ServerOptions` and `S3Server` for the public configuration/lifecycle surface.
- `HTTPServer`, `HTTPRequestParser`, and `HTTPResponseWriter` over `NWListener`/`NWConnection`.
- `S3RequestHandler` for method dispatch and XML responses.
- `SigV4Verifier` plus URI/query/header canonicalizers and hashing helpers.
- `BucketRouter` and `ObjectStore` for normalized paths, safety checks, atomic writes, reads, deletes, stats, and recursive listing.
- `ListObjectsV2` request/result/XML encoding types.
- `ServerOptionsParser` shared by the executable and parser unit tests.

Alternative considered: one direct translation of `index.ts`. Rejected because transport, cryptography, and filesystem behavior need isolated tests and clear concurrency ownership in Swift 6.

### 3. Implement a bounded HTTP/1.1 server with Network.framework

`NWListener` accepts TCP connections. A per-connection state machine incrementally parses the request line and case-insensitive headers, enforces header limits, determines framing from `Content-Length`, reads at most the configured body limit, and dispatches one request. Responses include an explicit length and close the connection, so keep-alive and pipelining are not required for compatibility with the current client.

Malformed requests receive an HTTP error without reaching S3 routing. `PUT`/`POST` bodies are accumulated because SigV4 payload verification occurs before dispatch, matching the reference. GET responses can write file data in bounded chunks after metadata is fixed.

Alternative considered: Foundation URL loading APIs. Rejected because they provide HTTP clients, not a dependency-free server. A bespoke socket loop was also considered, but Network.framework offers safer lifecycle and back-pressure primitives while remaining a system framework.

### 4. Preserve protocol behavior, not TypeScript accidents

Compatibility fixtures will pin canonical requests, derived signatures, status codes, required headers, and parsed XML fields. Dynamic values such as request UUIDs, mtimes, and random credentials are validated by shape or relationships rather than byte-for-byte snapshots. Debug-only `console.time` lines are excluded.

Error codes/messages and status mappings visible to clients are matched. HTTP header names remain case-insensitive. XML escapes all five reserved characters. Date rendering uses fixed POSIX locale, Gregorian calendar, and UTC to avoid machine-locale differences.

### 5. Port SigV4 as byte-exact, independently testable logic

Canonical URI uses per-segment percent decode/re-encode with RFC 3986 escaping. Canonical query retains duplicate values, sorts encoded key/value pairs, and excludes `X-Amz-Signature` only for presigned verification. Signed header names are normalized to lowercase; values are trimmed and internal whitespace collapsed. Credential scope, service, access key, payload hash, optional token, dates, expiration, and configured skew are validated in the same order as the reference where error observability matters.

The signing key is derived using HMAC-SHA256 and signatures are compared in constant time after strict hex decoding. Golden vectors cover both header and query authentication.

### 6. Centralize filesystem resolution and race-resistant checks

Configured paths expand `~`/`~/` against `HOME`, then become standardized absolute paths. Bucket names and decoded keys are validated before resolution. Every resolved path must equal or descend from its configured bucket root. Each existing path component is checked with `lstat` so symlinks cannot redirect reads or writes.

PUT creates parents, writes a uniquely named temporary sibling, and atomically renames it over the destination with cleanup on failure. Listing ignores non-regular files and does not follow symlink directories. Metadata and ETag generation reproduce the Bun formula (`MD5("\(size):\(mtimeMilliseconds)")`, quoted), including a defined millisecond conversion shared by PUT/GET/HEAD/LIST.

Alternative considered: Foundation path string prefix checks alone. Rejected because they do not prevent symlink escapes.

### 7. Make concurrency explicit under Swift 6

`S3Server` owns listener lifecycle in an actor or another `Sendable`-safe isolation boundary. Each connection is independently handled, while filesystem operations use system calls/Foundation off the listener callback path. Shared configuration is immutable. Shutdown stops accepting connections and cancels active connections so test teardown cannot leak ports.

### 8. Keep executable configuration behavior centralized and injectable

`ServerOptionsParser` accepts `[String]` and an environment dictionary. It implements the exact flag set, repeatable `--bucket-path`, one positional path, integer parsing semantics, environment fallback order, defaults, generated 16-byte lowercase-hex credentials, help text, validation errors, and exit statuses. `main` passes `CommandLine.arguments` and `ProcessInfo.processInfo.environment`, prints the same credential/directory/bucket/listening fields, and runs until signal termination.

This injection boundary allows deterministic unit tests without mutating the test process environment.

## Risks / Trade-offs

- [A hand-written HTTP parser can mishandle framing or malformed input] → Use an incremental state machine with explicit caps, reject ambiguous `Content-Length`/unsupported transfer encodings, fuzz parser chunks, and add fragmented-request integration tests.
- [Network.framework and CryptoKit narrow portability] → Declare the supported macOS platform in `Package.swift`, document it, and keep transport/crypto behind internal boundaries for a future system-only Linux adapter.
- [Filesystem check/use races can still exist between `lstat` and an operation] → Re-check immediately before mutation, never traverse listed symlinks, use sibling temp files and atomic rename, and document the local trusted-host threat boundary; prefer descriptor-relative system calls where practical.
- [Bun and Swift timestamps can produce different ETags due to precision] → Define millisecond truncation explicitly and verify ETag consistency within each object lifecycle and against controlled fixture mtimes.
- [Existing tests do not cover all code paths] → Expand the shared contract matrix for HEAD, presigning, session tokens, limits, skew, routing, pagination, malformed encodings, traversal, symlinks, errors, and CLI process behavior before declaring parity.
- [Fixed test ports create flakes] → Allocate ephemeral ports or retry-reserved ports and include child-process output in failures.
- [Loading authenticated request bodies can consume memory] → Enforce `Content-Length` early and the streaming byte counter always; unlimited mode intentionally retains reference semantics.

## Migration Plan

1. Establish shared fixtures and make the TypeScript integration suite run against the unchanged Bun server.
2. Add the dependency-free Swift target structure and focused unit tests.
3. Implement HTTP, authentication, routing, storage, and CLI in vertical slices, enabling corresponding contract cases as each slice lands.
4. Build the release `Server` executable and run the full TypeScript contract suite against both Bun and Swift.
5. Add documented package commands and CI verification.
6. Keep Bun as the default/reference executable until Swift parity is green; rollback consists of selecting the Bun backend because no storage format migration occurs.

## Open Questions

- Confirm the minimum supported macOS version. The implementation should choose the lowest version that supports the required Network/CryptoKit APIs and record it in `Package.swift`.
- Decide whether exact help text should continue saying `bun server` for byte compatibility or use a Swift-specific executable name. The default proposal is to preserve option semantics and content while allowing the invocation prefix to be asserted separately.
- Decide whether startup readiness should be signaled only by the existing listening log line or by a test-only inherited file descriptor. The default is log-line readiness to avoid adding production behavior.
