# ADR-0016: What a PIN is in this app

> **Status:** Accepted
> **Date:** 2026-10-21
> **Deciders:** Devstroop maintainers
> **Related:** [ADR-0007](0007-pin-hashing.md) (superseded),
> [`architecture/04`](../architecture/04-data-layer.md),
> [`plan/status.md`](../plan/status.md),
> [`plan/open-questions.md`](../plan/open-questions.md)

## Context

ADR-0007 decided that PINs are hashed with salted SHA-256. It was the
right decision at the time: v1 stored PINs in the clear, and a hash is
not a hash of nothing.

It was not enough, and the 2026-10-20 audit said why. A single fast
digest over a four-digit PIN is a list of ten thousand candidates, and
a stolen database - a backup, a laptop, a photograph of the screen -
turns into every PIN in the restaurant in seconds. The salt stops two
restaurants sharing a hash; it does not stop anyone guessing.

Three things have to be true at once, and they pull against each
other:

- **the hash must be slow**, or the database is a list;
- **the sign-in must find the employee by the hash it computes**, or
  every sign-in is a search over every employee;
- **the PIN must be long enough**, or a slow hash is a slow way to
  guess ten thousand things.

The salt is where the second one bites. A random per-employee salt
means the app cannot compute one hash and look it up: it would have to
hash the PIN once per employee, with a slow hash, for every sign-in.
That is a second of work at a keyboard, and a way to make the till
unresponsive under a guessing attack.

## Decision

**A PIN is six digits, hashed with bcrypt, salted with the
installation, and the till stops taking guesses.**

1. **Six digits or more, digits only.** The setup and every other
   place a PIN is chosen refuse anything shorter, and say why. Four
   digits is ten thousand guesses; six is a hundred times more.
2. **bcrypt, at a cost of 2^10 rounds.** The hash is bcrypt's own
   crypt string, so it carries its cost and its salt with it: the cost
   can be raised later, the old hashes still verify, and a hash written
   by a future version of the app is readable by this one.
3. **The salt is the installation's.** Two restaurants with the same
   PIN do not share a hash, and the sign-in still finds the employee by
   computing one hash.
4. **A PIN hashed before bcrypt still signs in**, and the row is
   rewritten in the modern form the moment it does. The old digest is
   worth nothing to an attacker with the database, and that moment is
   when it stops being worth something.
5. **The till stops after five wrong PINs, for a minute** - and the
   right PIN is refused too while it is stopped. The point is to stop
   the guessing, not to annoy the cashier.
6. **The sign-in verifies the hash the row holds**, not merely that a
   row matched.

## Consequences

### Positive

- A stolen database is not a list of PINs. Ten thousand guesses is
  still a day; a million is a season.
- The hash is versioned, so the cost can be raised as the hardware
  gets faster, and old hashes keep working while they are replaced.
- A restaurant that has been running keeps working: the old hashes
  verify, and they are replaced one sign-in at a time.
- The till is not a password oracle: five guesses a minute.

### Negative

- The sign-in pauses for about a tenth of a second while the hash is
  made. It is a once-per-shift action, and the pause is the point.
- The salt is per installation, not per employee. A database that is
  cracked gives up every PIN, not one. The fix is the sign-in finding
  the employee first, and that is a change to the flow, not to the
  hash.
- The failure counter lives in the session. A restart clears it, which
  a determined guesser would do.
- The PIN field is not masked. The SDK's text field has no password
  mode, and the gap is written down rather than worked around.
- Six digits is still not a password. A PIN is a name on a list, and
  the app treats it as one: it identifies the cashier, it does not
  protect the money.

### Follow-ups

- The mask, when the SDK grows one: a PIN typed on a screen in front
  of a customer is a PIN that a customer knows.
- The per-employee salt, when the sign-in can identify the employee
  before it hashes: an employee picker makes the salt per employee
  and the login one hash.
- The failure counter, when the sign-in can be written to the
  database: a counter that a restart clears is a counter that a
  restart is worth.
- The PIN policy for the employees an owner creates: the employee
  form has no PIN field yet, and the six-digit rule has to reach it
  when it does.

## Alternatives considered

- **Argon2id or scrypt.** Both are stronger against a GPU than bcrypt
  is, and both want tens of megabytes of memory for the derivation -
  which the model does not own, because the model is built with `.{}.`
  and must stay that way. bcrypt is deliberately slow, wants four
  kilobytes, and is in the standard library.
- **PBKDF2.** It is the recommendation in most places, and it is
  deliberately parallel: a GPU does millions of guesses a second,
  which is exactly what an attacker with a stolen database has. A slow
  memory-hard function is the better answer for a short secret.
- **A per-employee salt with the sign-in searching.** Correct, and
  unusable at a keyboard: a slow hash per employee per attempt.
- **Keeping four digits and raising the cost.** The cost can only go
  so far before the sign-in itself is unusable, and ten thousand
  guesses does not need a slow hash - it needs a longer secret.
- **Hardware-backed PIN entry.** Out of reach: the app is a desktop
  program with no access to a TPM, and the SDK has no API for it.
