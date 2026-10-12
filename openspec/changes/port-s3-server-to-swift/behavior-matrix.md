# Bun-to-Swift Behavior Matrix

This matrix inventories the observable branches in `index.ts` and `server.ts`. “Existing”
means covered by the pre-port Bun suite; “planned” points to the OpenSpec task that must
add the shared TypeScript contract or focused Swift test.

| Reference branch | Observable result | Mutation | Coverage |
|---|---|---|---|
| finite/negative body and skew limits | clamp to zero (unlimited) | none | Swift planned 3.5 |
| bucket mapping missing/blank/invalid name | constructor error | none | Swift planned 3.5 |
| `~`/`~/` with and without `HOME`; relative/absolute path | expanded normalized root or constructor error | none | Bun existing: home expansion; Swift planned 3.5 |
| start with default and bucket roots | creates roots; binds requested/ephemeral port | directories created | Bun existing; Swift planned 3.5 |
| stop once/repeatedly | listener closes and port is reusable | none | Swift planned 3.5/4.7 |
| body declared/received over configured limit | 413 `EntityTooLarge`, XML content type | none | TS planned 8.9; Swift planned 4.6 |
| body read failure | 500 `InternalError`, XML content type | none | Swift planned 4.6 |
| no authorization | 403 `AccessDenied`, XML content type | none | Bun existing: auth; TS planned 6.8 |
| unsupported/malformed authorization fields | 403 `AccessDenied` | none | Swift planned 6.7; TS planned 6.8 |
| wrong key/service/scope/date/token | 403 `AccessDenied` | none | Swift planned 6.7; TS planned 6.8 |
| missing date/host/signed header | 403 `AccessDenied` | none | Swift planned 6.7; TS planned 6.8 |
| expired presign | 403 `AccessDenied` | none | Swift planned 6.7; TS planned 6.8 |
| header time outside configured skew | 403 `RequestTimeTooSkewed` | none | Swift planned 6.7; TS planned 6.8 |
| malformed URI/query canonicalization | 403 `AccessDenied` | none | Swift planned 5.6/6.7 |
| payload digest mismatch | 403 `AccessDenied` | none | Swift planned 6.7; TS planned 6.8 |
| signature length/hex/value mismatch | 403 `AccessDenied` | none | Bun existing: wrong credentials; Swift planned 6.7 |
| missing bucket | 404 `NoSuchBucket` | none | TS planned 8.9 |
| invalid bucket/key encoding | 400 `InvalidURI` | none | Swift planned 7.5; TS planned 7.6 |
| virtual-host/path-style host rules | selected bucket/key | none | Swift planned 7.5 |
| no configured/default bucket root | 404 `NoSuchBucket` | none | Bun existing: bucket paths |
| traversal or symlink path | 400 `InvalidURI` | none outside root | Swift planned 7.5; TS planned 7.6 |
| bucket GET, list type absent/2 | 200 ListBucketResult XML | none | Bun existing: LIST |
| unsupported list type | 400 `InvalidRequest` | none | TS planned 9.6 |
| list prefix/delimiter/default max/cap | 200, exact contents/common prefixes | none | Bun existing: LIST delimiter; Swift planned 9.5 |
| list continuation | 200, truncation and next token fields | none | Swift planned 9.5; TS planned 9.6 |
| missing key for non-list operation | 400 `InvalidRequest` | none | TS planned 8.9 |
| PUT success/overwrite | 200 with quoted `ETag` | atomic object replacement | Bun existing: roundtrip/overwrite; Swift planned 8.8 |
| PUT write/rename failure | 500 `InternalError` | temp removed; old object preserved where possible | Swift planned 8.8 |
| HEAD existing/missing | 200 metadata/no body or 404 `NoSuchKey` | none | TS planned 8.9 |
| GET existing/missing | 200 bytes, length/date/ETag/MIME or 404 `NoSuchKey` | none | Bun existing: text/binary/missing; TS planned 8.9 |
| DELETE existing/missing | 204 or 404 `NoSuchKey` | deletes only existing target | Bun existing: DELETE |
| authenticated unsupported method | 405 `MethodNotAllowed` | none | TS planned 8.9 |
| XML dynamic/reserved text | escaped XML and nonempty request ID | none | Swift planned 8.8; TS planned 8.9 |
| CLI `--help`/`-h` | usage, exit 0, no listener/root | none | Bun existing; Swift planned 10.9/10.10 |
| positional/`--path`, ordinary/repeated flags | parsed values; arguments win | none | Bun existing; Swift planned 10.9 |
| PORT/S3/AWS/default precedence | reference option values | none | Swift planned 10.9/10.10 |
| integer prefix/invalid/negative | JS `parseInt` result, fallback, then normalization | none | Swift planned 10.9 |
| missing credentials | independent 32-char lowercase hex values | none | Swift planned 10.9/10.10 |
| malformed mapping/unknown/missing value/extra positional | useful error, nonzero exit, no listener | none | Swift planned 10.9/10.10 |
| normal CLI startup/logging/signals | credentials/roots/URL logged; clean signal exit | roots created; listener released | Swift planned 10.10 |
