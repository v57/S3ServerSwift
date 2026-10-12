## ADDED Requirements

### Requirement: SigV4 authorization-header verification
The server SHALL verify AWS4-HMAC-SHA256 authorization headers using the configured access key and secret, credential date/region/service scope, signed headers, request payload hash, and constant-time signature comparison.

#### Scenario: Valid signed header request
- **WHEN** a request has a valid S3 SigV4 authorization header and payload hash for the configured credentials
- **THEN** authentication SHALL succeed and routing SHALL continue

#### Scenario: Invalid signed header request
- **WHEN** authorization is missing, malformed, signed with another key, scoped to a non-S3 service, missing a signed host/header, or has a mismatched signature or payload hash
- **THEN** the server SHALL return `403 AccessDenied` without changing stored objects

### Requirement: SigV4 presigned URL verification
The server SHALL verify presigned requests using `X-Amz-Algorithm`, credential, signed headers, signature, date, expiration, query canonicalization excluding only the signature, and `UNSIGNED-PAYLOAD`.

#### Scenario: Valid unexpired presigned URL
- **WHEN** a presigned request is correctly signed and has not expired
- **THEN** authentication SHALL succeed

#### Scenario: Invalid or expired presigned URL
- **WHEN** the algorithm, expiration, signature, or required presign field is invalid, or the current time is later than the signed expiry
- **THEN** the server SHALL return `403 AccessDenied`

### Requirement: Canonical request parity
The server SHALL reproduce the reference canonical URI, canonical query, canonical headers, signed-header list, and payload hash rules byte-for-byte for valid UTF-8 request inputs.

#### Scenario: Encoded path and duplicate query values
- **WHEN** a signed URL contains percent-encoded path segments, RFC 3986 reserved characters, duplicate query keys, or differently ordered query pairs
- **THEN** the canonical request SHALL decode/re-encode path segments, RFC 3986-encode and sort query key/value pairs, and preserve duplicate pairs as the Bun reference does

#### Scenario: Header whitespace
- **WHEN** a signed header contains leading, trailing, or repeated internal whitespace
- **THEN** its canonical value SHALL be trimmed and runs of whitespace SHALL collapse to one space

### Requirement: Credential date and time controls
The server SHALL validate the AWS timestamp, require credential-date agreement, reject expired presigned URLs, and enforce header-authentication clock skew only when a positive maximum skew is configured.

#### Scenario: Excessive configured skew
- **WHEN** a header-signed request differs from current time by more than the configured positive maximum
- **THEN** the server SHALL return `403 RequestTimeTooSkewed`

#### Scenario: Unlimited skew
- **WHEN** maximum skew is zero and an otherwise valid header-signed request has an old timestamp
- **THEN** the server SHALL not reject it solely for clock skew

### Requirement: Optional session-token enforcement
The server SHALL require the configured session token in `x-amz-security-token` or `X-Amz-Security-Token` as applicable and SHALL not require a token when none is configured.

#### Scenario: Configured token
- **WHEN** a session token is configured and a signed request omits it or supplies a different value
- **THEN** the server SHALL return `403 AccessDenied`

### Requirement: Supported payload hash modes
The server SHALL support an explicit lowercase or uppercase SHA-256 hex value, `UNSIGNED-PAYLOAD`, and `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` to the same extent as the reference verifier.

#### Scenario: Explicit payload mismatch
- **WHEN** `x-amz-content-sha256` is a digest that does not match the received body
- **THEN** the server SHALL return `403 AccessDenied` and SHALL not persist the body
