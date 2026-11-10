<h1>
  <img alt="Containerization logo" src="icon.png" width="70" valign="middle">
  &nbsp;S3ServerSwift
</h1>
A dependency-free, Swift 6 S3-compatible server built on system frameworks only
(Foundation, Network, CryptoKit, Security). It is the Swift port of the Bun
[`s3` server](https://github.com/v57/s3) (`../s3` next to this checkout): the same S3 wire behavior, CLI and client-observable
errors, plus what an app embedding it needs.

It supports:
- `GET` object, with one `Range` (206, 416)
- `HEAD` object (size/metadata)
- `PUT` object, streamed to a temporary file next to the object
- `DELETE` object (and the folders it leaves empty)
- `ListObjectsV2`
- SigV4 auth (header and presigned URLs), checked from the request's head before
  any body byte is read
- Path-style bucket addressing (the host never names a bucket)
- Safe filesystem path handling (containment + symlink rejection)

## Requirements

macOS 13, iOS 16, tvOS 16 or visionOS 1; Swift 6.2. No package dependencies:

```swift
.package(url: "https://github.com/v57/S3ServerSwift.git", branch: "main")
// target dependency: .product(name: "S3ServerSwift", package: "S3ServerSwift")
```

## Building

```bash
swift build                # library + Server
swift test                 # unit + integration tests
swift build -c release --product Server
```

## Using the library

```swift
import S3ServerSwift

let options = try S3ServerOptions(
    host: "::",                             // every address, IPv4 and IPv6 ("0.0.0.0": IPv4 only)
    port: 0,                                // any free port
    bucketPaths: ["hub": "~/storage/hub"],
    key: "local-key",
    secret: "local-secret"
)

let server = S3Server(options: options, hooks: S3ServerHooks(
    // Answer only this device and an overlay network
    acceptsConnection: { address in address == "127.0.0.1" || address == "::1" || address.hasPrefix("100.") },
    // Before an upload's body is read, after its signature passed
    admitUpload: { upload in upload.length - upload.replacedSize > 1 << 30 ? .storageFull() : nil },
    // Objects stored or deleted through the server
    changed: { change in print(change) },
    // Once per admitted upload when it ended, stored or not: a quota holds its room until then
    uploadEnded: { upload in print("ended", upload.key) }
))
try await server.start()
let port = await server.boundPort!

// Links for clients that don't hold the keys
let presigner = S3Presigner(
    endpoint: URL(string: "http://127.0.0.1:\(port)")!,
    bucket: "hub", accessKeyID: "local-key", secretAccessKey: "local-secret"
)
let upload = presigner.url(method: "PUT", key: "folder/photo.heic", expires: 3600)

// The same storage in process
let listing = try server.storage.list(bucket: "hub", prefix: "folder/", delimiter: "/")
try server.storage.delete(bucket: "hub", key: "folder/photo.heic")

await server.stop()
```

`S3ServerOptions` expands `~`/`~/` from `HOME`, resolves relative paths against
the working directory, and validates bucket names. `S3Server.start()` creates
configured roots and binds the port; `isRunning` turns false when the listener
fails (an iPhone app suspended in the background), and `start()` again binds anew.
`S3Server.stop()` closes the listener and all active connections and is safe to
call repeatedly.

A request that carries a body and isn't presigned must name its payload hash in
`x-amz-content-sha256` (as the Bun server requires); the signature covers it, and
the body is compared with it once it's in. Unsigned requests, bad signatures, body
limits and refused uploads are answered from the head, and the connection closes
without reading the body.

## Using the executable

`Server` accepts the same flags, positional path, and environment variables as
the Bun CLI:

```bash
swift build -c release --product Server
.build/release/Server ~/storage --port 9002
.build/release/Server --path ~/storage --bucket-path photos=~/photos
.build/release/Server --help
```

Environment fallbacks: `PORT`, `S3_DATA_DIR`, `S3_ACCESS_KEY_ID` /
`AWS_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` / `AWS_SECRET_ACCESS_KEY`,
`S3_SESSION_TOKEN` / `AWS_SESSION_TOKEN`, `S3_MAX_BODY_BYTES`,
`S3_MAX_TIME_SKEW_SECONDS`. Explicit arguments win over environment. When no
credentials are supplied, independent 16-byte lowercase-hex values are generated
and printed at startup. `SIGINT`/`SIGTERM` stop the server and exit cleanly.

## Verification

```bash
swift test                           # unit tests; EmbeddingTests drives a running server with presigned links
Scripts/verify-no-dependencies.sh    # no package dependencies, no Package.resolved
```

The contract suite that keeps it interchangeable with the Bun server lives in the `s3` repository, next to this one:
`bun run test:swift` there builds this package's `Server` and runs `index.test.ts` and `server.cli.test.ts` against it.

## Intentional S3 non-goals

Multipart upload, multiple ranges, versioning, ACLs, bucket create/delete, and
TLS are not implemented. The HTTP transport supports keep-alive for sequential
requests but not pipelining of multiple in-flight requests on one connection.
