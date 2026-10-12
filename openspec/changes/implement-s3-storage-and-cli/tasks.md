## 1. Bucket and Object Path Resolution

- [x] 1.1 Implement path-style bucket/key parsing and the reference virtual-host detection rules for `localhost`, `.local`, IPs, two-label, and subdomain hosts, including host-bucket-wins-on-conflict behavior.
- [x] 1.2 Implement percent decoding and validation for buckets/keys, backslash-to-slash key normalization, required-key rules, and `400 InvalidURI` mapping for invalid encodings and malformed bucket names.
- [x] 1.3 Implement explicit per-bucket root lookup, default `<root>/<bucket>` fallback with default-root escape rejection, unconfigured-bucket detection (`404 NoSuchBucket`), and containment-safe object resolution (`400 InvalidURI` on escape).
- [x] 1.4 Implement component-by-component `lstat` symlink rejection for the bucket root and existing object path components, returning `400 InvalidURI` and never following links.
- [x] 1.5 Add Swift unit tests for every addressing rule, path normalization, encoded traversal, sibling-prefix traps, backslashes, malformed encodings, symlinked roots/components, and missing bucket mappings.

## 2. S3 Error/Status Table and Dispatch Skeleton

- [x] 2.1 Replace the `501` handler stub in `S3Server` with an authenticated dispatch seam (method → routing → storage) so unauthenticated requests never reach storage.
- [x] 2.2 Implement the shared S3 XML error document generator (escaped Code/Message, non-empty RequestId, `application/xml; charset=utf-8`) and the full client-observable error/status table, with reference error ordering (body limit → auth → bucket/key parse → validation → symlink → method dispatch).
- [x] 2.3 Return `400 InvalidRequest` for non-list requests without a key, `400 InvalidRequest` for unsupported `list-type`, and `405 MethodNotAllowed` for authenticated unsupported methods.

## 3. Object Operations

- [x] 3.1 Implement PUT: parent `mkdir -p`, unique sibling temp file, full write, atomic rename with the reference one-retry-on-failure path, temp cleanup on failure, and `200` with the post-rename ETag.
- [x] 3.2 Implement `413 EntityTooLarge` for declared `Content-Length` over the limit and for streamed byte-count over the limit, with no partial object persisted and temp data removed.
- [x] 3.3 Implement GET: regular-file lookup, binary response with content length, last-modified, ETag, and system-derived MIME with `application/octet-stream` fallback.
- [x] 3.4 Implement HEAD with GET-equivalent metadata and no response body.
- [x] 3.5 Implement DELETE with `204` for an existing file and `404 NoSuchKey` for a missing file.
- [x] 3.6 Implement the shared MD5 ETag helper (`MD5("<size>:<mtimeMilliseconds>")`, quoted lowercase hex) using the Bun millisecond truncation rule, used by PUT/GET/HEAD/LIST.
- [x] 3.7 Add Swift storage tests for text/binary/empty files, nested keys, overwrite atomicity, temp cleanup, missing objects, metadata consistency, MIME fallback, and unsupported methods.

## 4. ListObjectsV2

- [x] 4.1 Implement deterministic recursive enumeration of regular files with stable lexical ordering, skipping non-regular files and not following symlinked directories.
- [x] 4.2 Implement prefix pruning/filtering and delimiter grouping into unique sorted common prefixes at root and deeper prefixes.
- [x] 4.3 Implement `max-keys` parse/default/cap (1000), truncation detection, and `list-type=2` continuation-token resume semantics with `NextContinuationToken`.
- [x] 4.4 Implement the `ListBucketResult` XML with Name, Prefix, KeyCount, MaxKeys, IsTruncated, Contents (LastModified/ETag/Size/StorageClass), Delimiter, CommonPrefixes, and list-type-2 continuation elements, all escaped.
- [x] 4.5 Add Swift listing tests for empty buckets, ordering, prefix edge cases, delimiter levels, XML escaping, non-files/symlinks, max limits, multiple pages, and unsupported list type.

## 5. Server Executable and CLI Parity

- [x] 5.1 Implement an injectable `ServerOptionsParser` over argv and environment for every long/short flag, a single positional path, and repeatable `--bucket-path`.
- [x] 5.2 Reproduce argument-over-environment precedence (`S3` before `AWS`) for PORT/S3/AWS variables, defaults, optional token handling, and the `--path` > positional > `S3_DATA_DIR` > `.` data-root chain.
- [x] 5.3 Reproduce JavaScript `parseInt` integer-prefix/fallback semantics for port and limits, and pass parsed negative limits through library normalization.
- [x] 5.4 Generate independent 16-byte lowercase-hex access and secret credentials when omitted.
- [x] 5.5 Reproduce malformed bucket mapping, unknown option, missing value, and extra positional failure behavior with useful nonzero process exits.
- [x] 5.6 Implement help text with a successful zero exit and no root creation or listener startup.
- [x] 5.7 Implement executable startup logging (credentials, optional default directory, sorted/configured bucket mappings, actual listening URL).
- [x] 5.8 Replace the `Server/main` stub with the real entrypoint and install clean `SIGINT`/`SIGTERM` handling that stops the server and exits.
- [x] 5.9 Add Swift parser unit tests covering every option, precedence tier, repeatable mapping, help alias, integer edge case, default, generated credential shape, and invalid invocation.
- [x] 5.10 Add Bun process tests for compiled `Server` help, argv/env/working-directory behavior, startup output/readiness, generated credentials, invalid exits, and signal shutdown.

## 6. Full Compatibility, Quality, and Documentation

- [x] 6.1 Add matching TypeScript contract cases for HEAD, empty/binary content, metadata parity, body limits (declared and streamed), listing pagination/delimiter, traversal and symlink sentinel attempts, unsupported methods, and error XML.
- [x] 6.2 Run `swift test` and resolve all deterministic failures.
- [x] 6.3 Run the TypeScript suite in Bun-reference mode and confirm the port work did not regress the original library or CLI.
- [x] 6.4 Build the release `Server` product and run the complete shared TypeScript contract suite against it.
- [x] 6.5 Run stress checks for concurrent PUT/GET/LIST, repeated overwrite, oversized/malformed requests, and start/stop port reuse; verify no orphan processes, partial files, or temp upload files remain.
- [x] 6.6 Audit `Package.swift`, imports, and package state to confirm only system frameworks are used and no dependencies are declared.
- [x] 6.7 Update the README with supported platform/Swift version, the `Server` executable usage, the argv/environment contract, build commands, and intentional S3 non-goals.
- [x] 6.8 Document one-command verification for Swift tests, Bun tests, the contract backends, and the release executable.
- [x] 6.9 Run `openspec validate implement-s3-storage-and-cli --strict` and resolve all validation issues.
