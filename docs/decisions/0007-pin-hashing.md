# ADR-0007: Salted SHA-256 PIN hashing

> **Status:** Superseded by [ADR-0016](0016-what-a-pin-is.md)
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers
> **Related:** [`architecture/04`](../architecture/04-data-layer.md),
> [`plan/open-questions.md`](../plan/open-questions.md)
>
> **Superseded on 2026-10-21.** The digest is now bcrypt, the PIN is
> six digits, and the till stops taking guesses. The decision below is
> kept as the record of why hashing was the first step and what it did
> not solve.

## Context

v1 stored PINs where a curious operator could read them. A PIN is a
password, and a restaurant device is physically accessible to staff and
sometimes customers.

The Native SDK gives no password-hashing primitive. It does give SHA-256
through Zig's standard library and OS credentials storage through
`fx.credentials*`.

## Decision

**Hash PINs with SHA-256 over `salt || pin`, hex-encoded, with a
per-installation 32-byte salt stored in `app_config`.**

- The salt is generated once on a fresh install and never leaves the
  device.
- The database never sees a plaintext PIN.
- The login query matches `pin_hash` in SQL; only `id` and `name` return.
- Comparison in Zig uses a constant-time `equal` helper (currently used by
  tests, not by the login path, which compares in SQL).

## Consequences

### Positive

- No plaintext PIN on disk.
- Two restaurants with the same PIN do not share a hash.
- No extra dependency; works in the pure core.
- The login query is a single indexed read.

### Negative

- **SHA-256 is not a password KDF.** A 4-digit PIN has 10,000 candidates;
  a stolen database can be brute-forced in milliseconds even with a salt.
- **No rate limiting or lockout.** An attacker at the device can try PINs
  repeatedly.
- **No rehash/upgrade path.** If the algorithm changes, existing hashes
  need a migration on successful login.
- The salt is provisional at boot and confirmed by the database;
  `submit_login` does not yet check the provisional flag.
- A 6–8 digit numeric PIN is inherently low entropy; the threat model
  must accept that.

### Follow-ups

- Move to a memory-hard KDF if the SDK exposes one (Argon2id or scrypt),
  or use the OS keychain to store a pepper.
- Add attempt throttling and a lockout policy per employee/device.
- Add a rehash-on-login upgrade path.
- Resolve the provisional-salt race: `submit_login` must check
  `salt_is_provisional`, not just a non-empty salt.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Store PINs in plaintext | The v1 bug. |
| Unsalted hash | Rainbow-table trivial. |
| OS keychain only | Keychain protects secrets, not a lookup by PIN; still need a verifier. |
| HMAC with a device pepper in the keychain | Better, but the login query would need the pepper in SQL or a two-step lookup. Worth revisiting. |
| External auth service | Offline POS must work without a network. |

## Evidence

- `src/data/auth.zig`: `hashPin`, `makeSalt`, `equal`.
- `src/schema/0001_core.sql`: `employee.pin_hash`.
- `src/core/update.zig:61`: `login_sql`.
- Test: "a PIN is hashed, never stored".
