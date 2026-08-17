# Testing and verification

Compatibility claims in this project come from real-client runs, integration
tests, regression suites, differential checks, and packaged-binary smoke tests.
A code path existing is not by itself considered support.

## v0.1.0-preview.2 release matrix

The release gate completed **722 / 722** cases with all seven flows reporting
`connect=OK` and no proxy warnings:

| Flow | Result | What it represents |
|---|---:|---|
| python-oracledb thin | 125 / 125 | Pure-Python thin protocol path |
| go-ora | 123 / 123 | `github.com/sijms/go-ora/v2` |
| SQL*Plus | 97 / 97 | Thick OCI / Instant Client path |
| ojdbc | 123 / 123 | JDBC thin; also the family used by SQL Developer and DBeaver |
| ODP.NET managed | 123 / 123 | Managed .NET provider |
| Oracle 26ai DATABASE LINK | 129 / 129 | Modern database-link initiator |
| Oracle 19c DATABASE LINK | 2 / 2 | Legacy 19c database-link handshake and query path |

This is a versioned claim. A different driver or Oracle client version may use
different wire shapes. Run the actual client and workload you plan to deploy.

## Other release gates

The same release passed:

- `go build ./...` and `go vet ./...`;
- the complete Go test suite;
- race tests for the Oracle-wire package;
- 11 release-policy tests;
- 92.0% translator statement coverage;
- a PostgreSQL differential corpus with 166 pass, 0 fail, 1 documented skip,
  1 documented known bug, and 6 telemetry cases.

The packaged Linux amd64 archive—not a development binary—was unpacked into a
clean directory and run against a temporary PostgreSQL 16 instance with
`orafce`, dictionary views, and a real python-oracledb query. The Windows
preview archive is structurally checked and version-checked but does not yet
have a Windows live smoke gate.

## Verification scope

The matrix above is the public compatibility statement for this release. It
names the real client families exercised, the number of completed cases, and
the important gaps. A future release may change that scope, so use the notes
published with the exact binary version you deploy.

## Verify a downloaded release

```sh
# Linux
sha256sum -c SHA256SUMS

# macOS
shasum -a 256 -c SHA256SUMS

./orapglink --version
```

Release binaries are obfuscated with garble and stripped; they are not
encrypted. Checksums prove that the bytes match the published release, not that
the closed-source program is safe. Evaluate behavior in an isolated environment
and use the PostgreSQL runtime role to enforce least privilege.

## What is not claimed

- Every Oracle client or every version of a named client.
- Full Oracle SQL compatibility.
- Full SQL Developer object-tree emulation.
- Thick-OCI or database-link response shapes outside the validated set.
- Production suitability for an untested workload.
- Transport encryption on the Oracle listener.

The precise SQL boundary is in
[`TRANSLATOR_SUPPORT.md`](../TRANSLATOR_SUPPORT.md), and operational caveats are
in [`KNOWN_LIMITATIONS.md`](../KNOWN_LIMITATIONS.md).
