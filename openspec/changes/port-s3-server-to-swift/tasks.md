## 1. Compatibility Baseline and Package Structure

- [x] 1.1 Record a behavior matrix mapping every branch in `index.ts` and `server.ts` to an existing or planned TypeScript/Swift test, including status, S3 code, headers, and mutation outcome.
- [x] 1.2 Run and record the current Bun unit/integration suite as the pre-port compatibility baseline.
- [x] 1.3 Update `Package.swift` with the supported macOS platform, a dependency-free `S3ServerSwift` library product, and a `Server` executable product/target depending only on the library.
- [x] 1.4 Replace the generated placeholder source/test with module directories for configuration, HTTP transport, SigV4, S3 routing/XML, filesystem storage, CLI parsing, and test fixtures.
- [x] 1.5 Add a build-time/package-graph verification that fails if an external Swift package dependency is introduced.

## 2. Shared TypeScript Contract Harness

- [x] 2.1 Extract integration server setup/teardown from `index.test.ts` into a backend-neutral harness with configuration for Bun or Swift.
- [x] 2.2 Implement isolated temporary storage, generated/free ports, fixed test credentials, bounded readiness waiting, captured child output, and unconditional child/process cleanup.
- [x] 2.3 Add package scripts that build `Server` and run the same Bun test cases once against Bun and once against Swift.
- [x] 2.4 Refactor existing object, list, bucket-path, and home-expansion tests to use the shared harness without weakening assertions.
- [x] 2.5 Verify the refactored suite still passes in Bun-reference mode before using it as the Swift acceptance oracle.

## 3. Swift Configuration and Public Lifecycle

- [x] 3.1 Define public `S3ServerOptions` with host, port, default path, bucket paths, key, secret, optional session token, maximum body bytes, and maximum time skew.
- [x] 3.2 Normalize finite/negative limit values and validate/normalize configured bucket names and roots at construction with reference-compatible errors.
- [x] 3.3 Implement `~`/`~/` expansion from `HOME`, absolute/relative path resolution from the working directory, and missing-HOME failure cases.
- [x] 3.4 Implement `S3Server` start, bound-port reporting, idempotent stop, configured-root creation, and active-connection cleanup under Swift 6 concurrency checks.
- [x] 3.5 Add Swift unit tests for option normalization, path expansion, startup directory creation, ephemeral-port binding, repeated stop, and port release.

## 4. Dependency-Free HTTP/1.1 Runtime

- [x] 4.1 Implement `NWListener` TCP acceptance and a per-connection receive/send state machine using Network.framework.
- [x] 4.2 Implement incremental request-line, request-target, and case-insensitive header parsing across arbitrary receive chunk boundaries.
- [x] 4.3 Implement strict `Content-Length` body framing, early declared-size rejection, streamed received-size enforcement, and explicit rejection of malformed/ambiguous or unsupported transfer framing.
- [x] 4.4 Add bounded request-line/header limits and deterministic HTTP errors for malformed transport input without invoking S3 storage.
- [x] 4.5 Implement response serialization with status reason, headers, explicit content length, HEAD suppression, connection close, and chunked file-data sending with back-pressure.
- [x] 4.6 Add Swift parser/writer tests for fragmented requests, header casing, empty/binary bodies, invalid lengths, oversized headers, premature EOF, unsupported chunking, and exact response framing.
- [x] 4.7 Add parallel-connection and shutdown integration tests using ephemeral ports.

## 5. Cryptographic and Canonicalization Primitives

- [x] 5.1 Implement lowercase hexadecimal encoding/strict decoding, SHA-256, HMAC-SHA256, HMAC key derivation, MD5 compatibility hashing, and constant-time signature comparison with system CryptoKit.
- [x] 5.2 Implement RFC 3986 percent encoding and canonical URI segment decode/re-encode with invalid-encoding rejection.
- [x] 5.3 Implement canonical query construction that preserves duplicates, encodes keys/values, sorts by encoded pair, and conditionally excludes `X-Amz-Signature`.
- [x] 5.4 Implement signed-header parsing, lowercase normalization, required-host validation, missing-header detection, and whitespace-normalized canonical header serialization.
- [x] 5.5 Implement fixed-locale UTC AWS timestamp parsing, ISO-8601 list dates, HTTP Last-Modified dates, and credential-scope parsing.
- [x] 5.6 Add golden unit tests from AWS/reference fixtures for URI/query/header canonicalization, duplicate queries, Unicode/reserved characters, hashes, HMAC derivation, timestamps, and malformed inputs.

## 6. SigV4 Authentication

- [x] 6.1 Implement `AWS4-HMAC-SHA256` Authorization parsing and required Credential, SignedHeaders, and Signature validation.
- [x] 6.2 Implement header-signed canonical request and string-to-sign construction, access-key/service/date-scope checks, payload digest verification, and signing-key verification.
- [x] 6.3 Implement presigned URL field parsing, algorithm validation, `UNSIGNED-PAYLOAD`, signature-query exclusion, and expiration enforcement.
- [x] 6.4 Implement optional header/query session-token enforcement and reference-compatible behavior when no token is configured.
- [x] 6.5 Implement configured header-auth clock-skew enforcement while preserving unlimited behavior at zero and reference error ordering/codes.
- [x] 6.6 Support the reference payload markers `UNSIGNED-PAYLOAD` and `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` without claiming multipart/chunk-signature validation beyond the Bun behavior.
- [x] 6.7 Add Swift golden tests for valid/invalid header auth, presigned auth, wrong credentials/service/date/signature, missing host/signed headers, token cases, expired URLs, skew, and payload mismatch.
- [x] 6.8 Add matching TypeScript contract cases using Bun `S3Client` and independently constructed signed/presigned requests against both backends.

## 7. Bucket and Object Path Security

- [x] 7.1 Implement path-style parsing and the reference virtual-host bucket detection rules for localhost, `.local`, IPs, two-label endpoints, and subdomain hosts.
- [x] 7.2 Implement percent decoding and validation for buckets/keys, backslash normalization, required-key rules, and invalid-encoding mapping.
- [x] 7.3 Implement explicit per-bucket root lookup, default `<root>/<bucket>` fallback, unconfigured-bucket detection, and containment-safe resolution.
- [x] 7.4 Implement component-by-component `lstat` symlink rejection for bucket roots and existing object paths, and ensure recursive traversal never follows symlinks.
- [x] 7.5 Add Swift tests for all addressing rules, path normalization, encoded traversal, sibling-prefix traps, backslashes, malformed encodings, symlinked roots/components, and missing bucket mappings.
- [x] 7.6 Add process-level TypeScript contract cases proving traversal/symlink attempts cannot read or mutate sentinel files outside storage.

## 8. Object Operations and Metadata

- [x] 8.1 Implement XML escaping, XML response content type, S3 error documents with generated request IDs, and reference status/code/message mappings.
- [x] 8.2 Implement PUT parent creation, unique sibling temporary files, complete-data write, atomic replacement, failure cleanup, and response ETag.
- [x] 8.3 Implement GET regular-file lookup, binary response streaming, content length, modification date, ETag, and system-derived MIME type with octet-stream fallback.
- [x] 8.4 Implement HEAD with GET-equivalent metadata and no response body.
- [x] 8.5 Implement DELETE with `204` for an existing file and reference `404 NoSuchKey` behavior for a missing file.
- [x] 8.6 Implement quoted ETags from MD5 of the exact `size:mtimeMilliseconds` reference representation and use one metadata formatter across PUT/GET/HEAD/LIST.
- [x] 8.7 Implement authenticated rejection for missing bucket/key and unsupported methods without filesystem mutation.
- [x] 8.8 Add Swift storage tests for text/binary/empty files, nested keys, overwrite atomicity, temporary cleanup, missing objects, metadata consistency, MIME fallback, unsupported methods, and XML escaping.
- [x] 8.9 Expand shared TypeScript cases for HEAD, empty/binary content, metadata parity across operations, body limits via declared and streamed sizes, unsupported methods, and error XML.

## 9. ListObjectsV2

- [x] 9.1 Implement deterministic recursive enumeration of regular files with POSIX-style keys and stable lexical ordering.
- [x] 9.2 Implement prefix pruning/filtering and delimiter grouping into unique sorted common prefixes at root and deeper prefixes.
- [x] 9.3 Implement reference `max-keys` parsing/default/cap, truncation detection, continuation-token resume semantics, and next-token selection.
- [x] 9.4 Implement ListObjects/ListObjectsV2 request validation and XML fields for Name, Prefix, KeyCount, MaxKeys, IsTruncated, Contents, StorageClass, Delimiter, CommonPrefixes, ContinuationToken, and NextContinuationToken.
- [x] 9.5 Add Swift listing tests for empty buckets, ordering, prefix edge cases, delimiter levels, XML escaping, non-files/symlinks, max limits, multiple pages, and unsupported list type.
- [x] 9.6 Expand shared TypeScript tests to assert exact keys/common prefixes and traverse all continuation pages against both backends.

## 10. Server Executable and CLI Parity

- [x] 10.1 Implement an injectable `ServerOptionsParser` over argv and environment for every long/short flag, a single positional path, and repeatable `--bucket-path`.
- [x] 10.2 Reproduce argument-over-environment precedence for PORT/S3/AWS variables, default values, optional token handling, and S3-before-AWS credential fallbacks.
- [x] 10.3 Reproduce JavaScript `parseInt` integer-prefix/fallback semantics and pass parsed negative limits through library normalization.
- [x] 10.4 Generate independent random 16-byte lowercase-hex access and secret credentials when omitted.
- [x] 10.5 Match malformed bucket mapping, unknown option, missing value, and unsupported positional argument failure behavior with useful nonzero process exits.
- [x] 10.6 Implement help text and successful help exit without root creation or listener startup.
- [x] 10.7 Implement executable startup logging for credentials, optional default directory, sorted/configured bucket mappings, and actual listening URL.
- [x] 10.8 Keep the executable alive after startup and install clean SIGINT/SIGTERM handling that stops the server and exits.
- [x] 10.9 Add Swift parser unit tests covering every option, precedence tier, repeatable mapping, help alias, integer edge case, default, random credential shape, and invalid invocation.
- [x] 10.10 Add Bun process tests for compiled `Server` help, argv/env/working-directory behavior, startup output/readiness, generated credentials, invalid exits, and signal shutdown.

## 11. Full Compatibility, Quality, and Documentation

- [x] 11.1 Run `swift format` or the repository-selected formatter and compile all targets with Swift 6 warnings/concurrency diagnostics treated as errors where supported.
- [x] 11.2 Run `swift test` and resolve all deterministic unit/integration failures.
- [x] 11.3 Run the complete TypeScript suite in Bun-reference mode and confirm the port work did not regress the original library or CLI.
- [x] 11.4 Build the release `Server` product and run the complete shared TypeScript contract suite against it with no skipped Swift compatibility cases.
- [x] 11.5 Run stress checks for concurrent PUT/GET/LIST, repeated overwrite, oversized/malformed requests, and start/stop port reuse; verify no orphan processes, partial files, or temporary upload files remain.
- [x] 11.6 Audit `Package.swift`, imports, and resolved package state to confirm the implementation uses only system frameworks and declares no dependencies.
- [x] 11.7 Update the README with supported platform/Swift version, library and `Server` usage, the exact argv/environment contract, build commands, and known intentional S3 non-goals.
- [x] 11.8 Document one-command verification for Swift tests, Bun tests, both contract backends, and the release executable.
- [x] 11.9 Reconcile the completed implementation against every proposal requirement and behavior-matrix row, adding any missing regression test before marking the change complete.
- [x] 11.10 Run `openspec validate port-s3-server-to-swift --strict` and resolve all proposal/spec/task validation issues.
