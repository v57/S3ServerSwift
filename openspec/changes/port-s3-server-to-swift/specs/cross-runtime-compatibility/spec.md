## ADDED Requirements

### Requirement: Shared TypeScript contract harness
The TypeScript S3 integration suite SHALL select Bun or Swift through test configuration while reusing the same protocol assertions and Bun `S3Client` interactions for both implementations.

#### Scenario: Backend matrix
- **WHEN** the contract command runs for the Bun backend and for the built Swift backend
- **THEN** the same applicable test cases SHALL pass against both

### Requirement: Isolated external server lifecycle
The harness SHALL allocate isolated storage, credentials, and ports, launch the selected external executable when needed, wait for readiness with a bounded timeout, capture diagnostic output, and always terminate the process and remove fixtures.

#### Scenario: Startup failure
- **WHEN** the selected server exits or does not become ready before the timeout
- **THEN** the test SHALL fail with command/output diagnostics and SHALL leave no child process or storage fixture behind

### Requirement: Complete compatibility matrix
The shared suite SHALL cover authentication success/failure, header and presigned SigV4, session tokens, payload hashes, time skew, body limits, path and virtual-host routing, default/per-bucket/home roots, traversal and symlinks, PUT/overwrite/GET/HEAD/DELETE, content metadata, listing prefix/delimiter/pagination, unsupported methods/list types, malformed encodings, and S3 error responses.

#### Scenario: Port acceptance gate
- **WHEN** Swift implementation work is declared complete
- **THEN** every supported reference behavior SHALL have a passing shared contract case or a documented deterministic Swift unit/golden test

### Requirement: CLI compatibility tests
The test system SHALL exercise the compiled `Server` as a process with controlled argv, environment, working directory, stdout/stderr, and signals.

#### Scenario: CLI configuration matrix
- **WHEN** the executable is launched across argument, environment, default, help, error, and generated-credential cases
- **THEN** its resolved behavior and process outcome SHALL match the server CLI specification

### Requirement: Swift-focused unit verification
The package SHALL include deterministic Swift tests for HTTP parsing, option parsing, RFC 3986 canonicalization, SigV4 golden vectors, constant-time signature input validation, XML escaping, bucket/key routing, path containment, listing, dates, and ETag generation.

#### Scenario: Package test gate
- **WHEN** `swift test` runs
- **THEN** all core logic SHALL be testable without binding fixed global ports or relying on the developer's environment

### Requirement: Automated verification commands
The repository SHALL provide documented repeatable commands that build the Swift executable, run Swift tests, run the Bun reference suite, and run the TypeScript compatibility suite against Swift.

#### Scenario: Clean checkout verification
- **WHEN** a contributor follows the documented verification commands on a supported machine with Bun and Swift installed
- **THEN** all required artifacts SHALL build and the complete parity test matrix SHALL execute
