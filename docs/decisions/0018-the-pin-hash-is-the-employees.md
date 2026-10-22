# ADR-0018: The PIN hash is the employee's

> **Status:** Proposed
> **Date:** 2026-10-22
> **Deciders:** Eatery maintainers
> **Related:** [ADR-0016](0016-what-a-pin-is.md) (decision 3 is
> replaced by this one; the rest of it stands),
> [ADR-0017](0017-three-apps-over-tcp-ip.md),
> [`architecture/12`](../architecture/12-three-apps-and-ipc.md),
> [`plan/phase-9`](../plan/phase-9-three-apps-and-ipc.md)

## Context

ADR-0016 decided three things about a PIN: it is six digits, it is
hashed with bcrypt at a cost of 2^10, and **the salt is the
installation's**. The third of those was a consequence of the second
and of how the sign-in worked, not a free choice.

The sign-in found the employee **by the hash**: it computed one hash
from the PIN and the installation salt and asked the database which row
owned it. For that to work the hash had to be findable, so the hash
could not be salted at random - it had to be derived from something
the app could reproduce. The installation salt was that something.

ADR-0016 named the cost of the choice: *"The salt is per installation,
not per employee. A database that is cracked gives up every PIN, not
one. The fix is the sign-in finding the employee first, and that is a
change to the flow, not to the hash."* It recorded the fix as a
follow-up: *"The per-employee salt, when the sign-in can identify the
employee before it hashes: an employee picker makes the salt per
employee and the login one hash."*

The three-app split forced the question. [ADR-0017](../decisions/0017-three-apps-over-tcp-ip.md)
makes three apps out of one, and each app has its **own** engine-owned
database in its **own** data directory - the database is pathless and
`ATTACH` is denied, so they cannot share a file. A `service` app that
has to let a waiter in therefore has to check a PIN against a hash
made on the `admin` app, and the installation salt - the one thing the
hash is derived from - does not travel with it.

The SDK gives no way out of that. There is no randomness effect:
`update` is pure, and a salt it made itself would have to be drawn
from somewhere it cannot reach.

## Decision

**The bcrypt salt is derived from the installation salt AND the
employee's id, and the sign-in identifies the person before it hashes.**

1. **The picker names the person.** The first screen lists the people
   who work here, and the device modes that sign in by being the
   device. Choosing a person says who is using the device, and their
   stored role says which mode they work in - so the picker does not
   ask twice.
2. **The salt is derived, not random.** `deriveSalt` takes the
   installation salt and the employee's id, and mixes the id in whole.
   Every bit of the id changes the salt, so two employees can never
   land on the same one. The id is known when the hash is made: the
   setup's first employee is id 1 and is named in one place, and the
   sign-in already knows which person it is checking.
3. **The sign-in verifies the row's hash; it does not look it up.**
   The query asks the database for the employee the picker chose, and
   the row's hash is checked against the PIN. A bcrypt string carries
   its own salt, so the check needs **nothing but the PIN** - which is
   what lets a second device check a PIN it was never given the
   installation salt for.
4. **The installation salt does not travel.** What crosses the wire is
   the employee row, hash and all. There is no shared secret in the
   protocol, so there is no secret to protect on it.
5. **An old digest still verifies.** A hash from before bcrypt is
   salted with the installation, so verifying it needs the
   installation salt, and the sign-in waits for the database to confirm
   it. The digest is rewritten in the modern form on the next sign-in,
   after which the row needs nothing else.

## Consequences

### Positive

- **The three-app blocker is gone.** A `service` app can let a waiter in
  from the employee row alone. There is no secret in the protocol.
- **A database that is cracked gives up one PIN, not every PIN.** Two
  employees with the same PIN have different hashes, and neither hash
  is the other's.
- **One slow hash per sign-in, not one per candidate.** The sign-in
  makes no hash at all to find the person: the row's own hash checks
  the PIN.
- **The sign-in got simpler.** It used to compute a hash, look up a
  row by equality, and then verify the row's hash anyway. Now it
  looks up the person and verifies.
- **A person is a person, and a device is a device.** The picker says
  who; the device modes sign in by being the device. Nobody types a
  PIN into a kitchen board, and no employee is signed in by device.

### Negative

- **A person has to identify themselves before they can sign in.** It
  is one more tap, and it is a flow change the operator sees.
- **The employee's id is part of the hash's derivation.** An employee
  whose id changed would need their PIN reset. Ids are assigned once
  and never reused.
- **The installation salt still exists**, and it is still the thing
  that scopes a hash to a restaurant. It is needed to make a hash and
  to check an old one, and nothing else.
- **The two modes of signing in are now two different paths.** A
  person proves who they are; a device does not. The permission matrix
  is unchanged, but the flow that reaches it is.

### Follow-ups

- The employee form has no PIN field yet. When it grows one, the id
  has to be known before the hash is made - the form assigns the id,
  or the hash is written after the insert.
- A legacy employee signing in on a device that has no installation
  salt cannot be checked. The admin app rewrites the digest, and after
  that the row travels on its own.
- Whether the picker filters out employees whose role the device
  cannot run. It lists everybody today.

## Alternatives considered

| Alternative | Why not |
|---|---|
| A random salt per hash, stored on the employee | `update` has no randomness to draw from, and the SDK has no randomness effect. A salt drawn outside `update` cannot be produced at the moment a PIN is set. |
| Replicate the installation salt to every device | It puts a shared secret on the wire in plaintext, and it makes every device as sensitive as the admin's. The whole point of the per-employee salt was to stop one database giving up every PIN. |
| Keep the salt as it is and find the employee by hash | The sign-in still needs the installation salt to compute the hash it looks up, so the same secret has to travel. And the sign-in still hashes once per candidate. |
| The sign-in asks the admin app to check the PIN | The admin app would have to be online for anyone to sign in, which is the case the three-app split exists to survive. |
| Derive the salt from the employee's name | A name is not unique, and a rename would break the PIN. |
| Store a random per-employee salt in a new column | The right answer for a system with randomness. This one has none, and the derivation gets the same property - two employees never share a hash - without a column. |

## Evidence

- `src/data/auth.zig`: `hashPin` and `deriveSalt` - the salt is
  derived from the installation salt and the id.
- `src/data/repos.zig`: `login_sql` asks for the employee the picker
  chose, and `first_employee_id` names the setup's employee once, for
  both the insert and the hash.
- `src/core/update.zig`: `pick_employee` and `login_checked` - the
  person is chosen first, and the row's hash is verified against the
  PIN.
- `src/tests.zig`: "two employees with the same PIN have different
  hashes".
- `src/tests_data.zig`: "the sign-in checks one person, not the whole
  staff list" - the sign-in makes no hash to look the person up.
- The SDK has no randomness effect: `grep -n "pub fn random" src/runtime/effects.zig`
  finds nothing, and `update` has no `Io` to draw from.
