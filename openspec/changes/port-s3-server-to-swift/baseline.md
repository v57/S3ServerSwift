# Pre-port Compatibility Baseline

Recorded on 2026-07-25 in the repository root.

```text
$ bun test
bun test v1.3.14 (0d9b296a)
25 pass
0 fail
43 expect() calls
Ran 25 tests across 2 files. [85.00ms]
```

Coverage at baseline:

- `server.test.ts`: 5 passing CLI parsing/help tests.
- `index.test.ts`: 20 passing authentication, PUT/GET, DELETE, listing,
  delimiter, bucket-path, and home-expansion tests.

This result is the Bun-reference acceptance baseline. Newly shared contract cases may
increase the count, but Bun-reference mode must remain green.
