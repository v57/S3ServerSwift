## Why

`S3ServerSwift` is currently an empty Swift package while the repository's Bun implementation already defines a working local S3-compatible server and a TypeScript compatibility suite. A dependency-free Swift port is needed that can replace the Bun server without changing client-visible HTTP behavior or the way test processes configure and launch the executable.

## What Changes

- Implement the complete S3 server as a reusable Swift library using only Swift standard-library facilities and Apple/system frameworks.
- Add a `Server` executable product and target that reads command-line arguments and environment variables with the same names, defaults, fallback order, validation, help behavior, and startup output as `server.ts`.
- Implement the Bun server's HTTP surface: authenticated `PUT`, `GET`, `HEAD`, and `DELETE` object operations plus bucket `ListObjectsV2`.
- Implement AWS Signature Version 4 authentication for authorization headers and presigned URLs, including canonicalization, payload validation, credentials, optional session tokens, expiration, and configured clock-skew enforcement.
- Preserve storage behavior including default and per-bucket roots, home-directory expansion, atomic replacement, metadata generation, MIME responses, traversal containment, and symlink rejection.
- Refactor the current TypeScript integration suite into a server-implementation-neutral contract harness and run it against the Swift `Server` executable, while retaining Bun implementation coverage.
- Add focused Swift unit tests for parsing, canonicalization, cryptography, routing, storage safety, XML generation, and other edge cases that are impractical to isolate through the process-level TypeScript suite.
- Document supported platforms, build/run commands, configuration, compatibility testing, and the intentional no-third-party-dependency constraint.

## Capabilities

### New Capabilities

- `swift-s3-server`: Public Swift library and system-framework HTTP runtime implementing the repository's S3-compatible request and storage behavior.
- `s3-authentication`: AWS SigV4 header and presigned-request verification compatible with the Bun implementation.
- `s3-object-storage`: Secure filesystem-backed object operations, bucket routing, metadata, and ListObjectsV2 behavior.
- `server-cli`: `Server` executable configuration, lifecycle, help, and startup output compatible with `server.ts`.
- `cross-runtime-compatibility`: A shared TypeScript contract suite that launches and validates both Bun and Swift server implementations.

### Modified Capabilities

None.

## Impact

- `S3ServerSwift/Package.swift` gains the `Server` executable and the package receives the complete library/runtime implementation and Swift tests.
- `index.test.ts`, `server.test.ts`, and package scripts/test helpers are updated so the existing TypeScript assertions can target an externally launched Swift server.
- CI and local verification must build Swift and run both Swift unit tests and Bun-driven compatibility tests.
- The Swift package may import system modules/frameworks such as Foundation, Network, CryptoKit/CommonCrypto, and Darwin/Glibc as platform-appropriate, but its package manifest will declare no external package dependencies.
- The existing Bun library remains the compatibility reference and is not removed.
