<h1>
  <img alt="Containerization logo" src="icon.png" width="70" valign="middle">
  &nbsp;S3ServerSwift
</h1>
A dependency-free, Swift 6 S3-compatible server built on system frameworks only
(Foundation, Network, CryptoKit, Security). It is the Swift port of the Bun
[`s3` server](https://github.com/v57/s3) and is an interchangeable drop-in replacement: same
S3 wire behavior, same CLI, same client-observable errors.

It supports:
- `GET` object
- `HEAD` object (size/metadata)
- `PUT` object
- `DELETE` object
- `ListObjectsV2`
- SigV4 auth (header and presigned URLs)
- Path-style and virtual-host bucket addressing
- Safe filesystem path handling (containment + symlink rejection)

## Requirements

- macOS 13+ (Swift 6, Xcode 16 or a recent Swift toolchain)

## Building

```bash
swift build                # library + tests
swift test                 # unit + integration tests
swift build -c release --product Server   # the Server executable
```

## Using the library

Add `S3ServerSwift` as a package dependency (this repository), then import it:

```swift
import S3ServerSwift

let options = try S3ServerOptions(
    host: "0.0.0.0",
    port: 9000,
    path: "~/storage",                      // optional default root
    bucketPaths: [
        "photos": "~/storage/photos",       // optional per-bucket roots
        "backups": "~/storage/backups",
    ],
    key: "local-key",
    secret: "local-secret",
    sessionToken: nil,
    maximumBodyBytes: 0,                    // 0 = unlimited
    maximumTimeSkewSeconds: 0               // 0 = no skew enforcement
)

let server = S3Server(options: options)
try await server.start()
print("listening on port \(await server.boundPort ?? 0)")

// ... later
await server.stop()
```

`S3ServerOptions` expands `~`/`~/` from `HOME`, resolves relative paths against
the working directory, and validates bucket names. `S3Server.start()` creates
configured roots and binds the port; `S3Server.stop()` closes the listener and
all active connections and is safe to call repeatedly.

## Using the executable

`Server` accepts the same flags, positional path, and environment variables as
the Bun CLI:

```bash
# Build
swift build -c release --product Server
# Run with a storage root and custom port
.build/release/Server ~/storage --port 9002
# Or with per-bucket roots
.build/release/Server --path ~/storage --bucket-path photos=~/photos
# See all options
.build/release/Server --help
```

Environment fallbacks: `PORT`, `S3_DATA_DIR`, `S3_ACCESS_KEY_ID` /
`AWS_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` / `AWS_SECRET_ACCESS_KEY`,
`S3_SESSION_TOKEN` / `AWS_SESSION_TOKEN`, `S3_MAX_BODY_BYTES`,
`S3_MAX_TIME_SKEW_SECONDS`. Explicit arguments win over environment. When no
credentials are supplied, independent 16-byte lowercase-hex values are generated
and printed at startup. `SIGINT`/`SIGTERM` stop the server and exit cleanly.

## Verification

The shared TypeScript contract suite in the `s3` repository (next to this one) runs the same cases against both the Bun
reference and this Swift server:

```bash
cd ../s3
bun run test:bun      # Bun reference
bun run test:swift    # build Server + contract + CLI process tests
```

`Scripts/verify-no-dependencies.sh` fails the build if any external
Swift package dependency is introduced.

## Intentional S3 non-goals

Multipart upload, ranged GET, versioning, ACLs, bucket create/delete, and TLS are
not implemented. The HTTP transport supports keep-alive for sequential requests
but not pipelining of multiple in-flight requests on one connection.
