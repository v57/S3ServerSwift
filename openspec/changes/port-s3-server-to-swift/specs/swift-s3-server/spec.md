## ADDED Requirements

### Requirement: Reusable Swift server API
The package SHALL expose a public Swift server configuration and lifecycle API capable of starting and stopping the S3-compatible service with host, port, storage roots, credentials, session token, body limit, and time-skew options.

#### Scenario: Library consumer starts and stops a server
- **WHEN** a consumer constructs the server with valid options and calls start
- **THEN** the server SHALL create configured roots, bind the requested endpoint, accept requests, report its bound port, and release the listener when stopped

### Requirement: Dependency-free package
The Swift package SHALL declare no external package dependencies and SHALL implement runtime functionality using only the Swift standard library and system frameworks.

#### Scenario: Package dependency inspection
- **WHEN** `Package.swift` and the resolved package graph are inspected
- **THEN** no third-party or remote package dependency SHALL be present

### Requirement: HTTP request serving
The server SHALL accept HTTP/1.1 requests needed by the Bun S3 client, parse request targets and case-insensitive headers incrementally, read framed bodies safely, and emit complete status lines, headers, and bodies.

#### Scenario: Fragmented request
- **WHEN** a valid signed request arrives across multiple network reads
- **THEN** the server SHALL reconstruct and process it identically to a request arriving in one read

#### Scenario: Malformed framing
- **WHEN** a request has malformed headers, invalid content length, unsupported transfer framing, or exceeds protocol header limits
- **THEN** the server SHALL reject it without dispatching a partial S3 operation or crashing

### Requirement: Concurrent lifecycle safety
The server SHALL support independent concurrent connections under Swift 6 concurrency checking and SHALL shut down without leaking listeners or test processes.

#### Scenario: Parallel clients and shutdown
- **WHEN** multiple clients perform object operations and the owner subsequently stops the server
- **THEN** valid operations SHALL be isolated from one another and the bound port SHALL be released

### Requirement: S3 XML and HTTP response compatibility
The server SHALL return the same client-observable status codes, S3 error codes/messages, relevant headers, and XML structure as the Bun reference for supported and rejected operations.

#### Scenario: Dynamic error response
- **WHEN** a request produces an S3 error
- **THEN** the response SHALL have XML content type, escaped Code and Message elements, and a non-empty RequestId

#### Scenario: Unsupported operation
- **WHEN** an authenticated request uses a method not implemented by the reference server
- **THEN** the response SHALL be `405` with S3 code `MethodNotAllowed`
