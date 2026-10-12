## MODIFIED Requirements

### Requirement: S3 XML and HTTP response compatibility
The server SHALL return the same client-observable status codes, S3 error codes/messages, relevant headers, and XML structure as the Bun reference for supported and rejected operations.

#### Scenario: Dynamic error response
- **WHEN** a request produces an S3 error
- **THEN** the response SHALL have XML content type, escaped Code and Message elements, and a non-empty RequestId

#### Scenario: Unsupported operation
- **WHEN** an authenticated request uses a method not implemented by the reference server
- **THEN** the response SHALL be `405` with S3 code `MethodNotAllowed`

#### Scenario: Dispatch behind authentication
- **WHEN** an unauthenticated request targets any storage operation
- **THEN** the server SHALL return the authentication error and SHALL not dispatch to routing or storage

#### Scenario: Replacing the not-implemented stub
- **WHEN** an authenticated request targets a supported object or list operation
- **THEN** the server SHALL dispatch it to storage and SHALL no longer return `501` for any authenticated request
