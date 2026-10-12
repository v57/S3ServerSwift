## MODIFIED Requirements

### Requirement: Argument compatibility
The executable SHALL accept one positional storage path and the reference flags `--help`/`-h`, `--host`, `--port`, `--path`, `--key`, `--secret`, `--session-token`, `--max-body-bytes`, `--max-time-skew-seconds`, and repeatable `--bucket-path bucket=path`.

#### Scenario: Positional and explicit arguments
- **WHEN** a positional path, ordinary flags, or repeated bucket mappings are supplied
- **THEN** they SHALL parse to the same option values and precedence as `parseServerOptions`

#### Scenario: Invalid arguments
- **WHEN** an unknown flag, missing flag value, extra unsupported positional, or malformed bucket mapping is supplied
- **THEN** startup SHALL fail with a nonzero exit and a useful diagnostic without binding a server

#### Scenario: Injectable parser boundary
- **WHEN** the executable and its unit tests parse the same argv and environment through the shared `ServerOptionsParser`
- **THEN** both SHALL resolve identical options without mutating the test process environment

### Requirement: Environment compatibility and precedence
The executable SHALL read `PORT`, `S3_DATA_DIR`, `S3_ACCESS_KEY_ID`, `AWS_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `AWS_SECRET_ACCESS_KEY`, `S3_SESSION_TOKEN`, `AWS_SESSION_TOKEN`, `S3_MAX_BODY_BYTES`, and `S3_MAX_TIME_SKEW_SECONDS` with the same fallback order as the Bun CLI; explicit arguments SHALL win.

#### Scenario: Complete precedence chain
- **WHEN** command arguments and both S3-prefixed and AWS fallback variables provide competing values
- **THEN** the resolved value SHALL follow argument, S3 environment, AWS environment, and default order where each is applicable

#### Scenario: Data path precedence
- **WHEN** a positional path, `--path`, and `S3_DATA_DIR` are all absent
- **THEN** the executable SHALL default the storage root to `.`; otherwise `--path` SHALL win over the positional path and the positional path SHALL win over `S3_DATA_DIR`

### Requirement: Defaults and generated credentials
The executable SHALL default host to `0.0.0.0`, port to `9000`, data path to `.`, body and skew limits to unlimited/zero, token to absent, and SHALL generate independent 16-byte lowercase hexadecimal key and secret values when credentials have no argument or environment source.

#### Scenario: Empty configuration
- **WHEN** the executable starts with no relevant arguments or environment
- **THEN** it SHALL use all reference defaults and print usable generated credentials

#### Scenario: Credential shape
- **WHEN** access key and secret are generated rather than supplied
- **THEN** each SHALL be an independent 32-character lowercase hexadecimal string

### Requirement: Help and startup behavior
Help SHALL describe all supported options and examples and exit successfully without starting a listener. Normal startup SHALL create roots, print credentials and configured locations, print the listening URL, remain active, and terminate cleanly on process signals.

#### Scenario: Help
- **WHEN** `Server --help` or `Server -h` is invoked
- **THEN** usage text SHALL be written, exit status SHALL be zero, and no port SHALL be bound

#### Scenario: Managed process lifecycle
- **WHEN** the test harness launches a normally configured Server and later sends a termination signal
- **THEN** readiness SHALL be observable from startup output and the process SHALL close its listener and exit

#### Scenario: Startup output
- **WHEN** the executable starts normally
- **THEN** it SHALL print the access key, secret key, configured default root, sorted configured bucket mappings, and the resolved listening URL
