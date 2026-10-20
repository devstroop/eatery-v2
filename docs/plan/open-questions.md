# Open questions

> **Status:** Living document. Expected to grow.
> **Last reviewed:** 2026-10-20.
> **Related:** [`risks.md`](risks.md), [`status.md`](status.md).

This page exists because the most expensive mistakes in a rewrite are the
questions nobody wrote down. It separates:

- **known unknowns** — we know we do not know;
- **unknown unknowns** — areas where we do not yet know what to ask;
- **questions we have answered** — kept briefly so they are not reopened.

An answer belongs here only when it is backed by evidence: a v1 code path,
a test, a spike, a hardware trial, a legal review, or an explicit product
decision. "Probably" is not an answer.

---

## How we will find out

| Method | Best for | Cost |
|---|---|---|
| Read the v1 code path and its tests | Behaviour that already exists | Low |
| Capture golden flows from v1 (`native automate`, screen recordings) | Interaction and copy | Medium |
| Port a calculation with v1 tests as the oracle | Money, tax, rounding | Medium |
| Spike in the SDK (throwaway app) | Platform capability limits | Medium |
| Hardware trial | Printing, scanners, drawers | Medium/high |
| Operator interviews and shadowing | Workflow, workarounds, error cost | Medium |
| Pilot service in one restaurant | Everything the above missed | High |
| Telemetry (opt-in) | Real usage, failure rates | Medium + privacy work |
| Legal/accounting review | Receipts, tax, data retention | External |

Rule: a question that blocks a phase must have an owner and a resolution
date before that phase starts.

---

## A. Product behaviour we have not captured

| # | Question | Why it matters | How to resolve | Owner | Status |
|---|---|---|---|---|---|
| A1 | What exactly does v1 do for tax: per product, per category, inclusive or exclusive, multiple slabs? | Every total and receipt depends on it | Read `order.function.dart`, port tests, confirm with an accountant | Product/Eng | Open |
| A2 | How are discounts applied: line, order, percentage, fixed, coupon, happy hour? | Affects the order write and reporting | v1 code + product decision | Product | Open |
| A3 | Are split payments, partial payments, tips, service charge or refunds in v1? | Payment schema and UI | v1 code + product | Product | Open |
| A4 | What is the void/refund policy and who may do it? | Audit, compliance, RBAC | v1 code + legal | Product | Open |
| A5 | What does "completed" mean: paid, served, or closed? | Status machine and reports | v1 code + interviews | Product | Open |
| A6 | Can an order be edited after placement, and which fields? | Immutability rule vs reality | v1 code + interviews | Product | Open |
| A7 | What are the waiter flows: transfer table, split bill, course timing, merge tables? | Waiter is one of four roles | v1 code + shadowing | Product | Open |
| A8 | What does the customer display actually show: one order, a queue, a carousel? | Display board design | v1 code + store visit | Product | Open |
| A9 | Does the kitchen route by station on day one? | `kds_station` schema is unused | v1 code + kitchen interview | Product | Open |
| A10 | Are modifiers required, and how are min/max enforced? | POS flow and order write | v1 code | Product | Open |
| A11 | What does a receipt legally require in each target market? | Printing and compliance | Legal/accounting review | Product | Open |
| A12 | Is a shift/X/Z report required, and what must it contain? | Compliance tables are unused | v1 code + accountant | Product | Open |
| A13 | Is loyalty used in practice? | Three tables exist, none used | Usage data / interviews | Product | Open |
| A14 | Are reservations used? | Table + validation exist, no UI | Usage data | Product | Open |
| A15 | What is the setup experience: wizard, import, or both? | A fresh install cannot log in today | v1 wizard code + interviews | Product | Open |
| A16 | Does a restaurant expect multi-company? | The schema enforces one | v1 usage + sales input | Product | Open |
| A17 | What are the error messages an operator can act on? | Error copy is currently technical | Shadowing + support tickets | Design | Open |
| A18 | Which reports does an owner actually open? | Report scope and queries | Usage data + interviews | Product | Open |
| A19 | What is the day boundary and timezone for reporting? | Epoch-ms is UTC; reports are local | Accountant + product | Product | Open |
| A20 | What happens when two waiters edit one table? | Shared model and sync | Interviews + pilot | Product | Open |

## B. Data and migration

| # | Question | Why it matters | How to resolve | Owner | Status |
|---|---|---|---|---|---|
| B1 | Must an installed v1 database migrate in place, or is a fresh install acceptable? | Drives Phase 2 vs Phase 8 | Customer/sales input | Product | Open |
| B2 | How many live v1 databases are there, and what shape are they in? | Migration effort and edge cases | Support data; collect anonymised copies | Eng | Open |
| B3 | What do v1 REAL money values actually contain (rounding artefacts, negative values)? | Conversion correctness | Query real copies | Eng | Open |
| B4 | Which v1 date formats exist in the wild? | STRICT conversion | Query real copies | Eng | Open |
| B5 | Are there orphan rows or broken foreign keys in v1? | STRICT + FK will reject them | Validation script on copies | Eng | Open |
| B6 | Are the eight unrepresented v1 tables used by any customer? | Whether to port or drop | Usage data | Product | Open |
| B7 | What is the maximum realistic menu size, table count, order history, customer count? | Bump capacities, paging, node budget | Customer data + interviews | Eng | Open |
| B8 | How long must order history be retained? | Schema, backup, privacy | Legal/customer | Product | Open |
| B9 | Is a backup required, and where may it go (local, Drive, other)? | Data safety and OAuth scope | Product + security | Product | Open |
| B10 | Does any customer rely on XLSX import/export? | CSV-first decision | Customer interviews | Product | Open |
| B11 | Are images (product photos, logos) used, and where are they stored? | File handling, backup, printing | v1 data + interviews | Product | Open |
| B12 | What is the v1 order-number format customers expect? | Invoices, receipts, staff habits | v1 code + interviews | Product | Open |
| B13 | Can order numbers repeat across devices or days? | Uniqueness and legal numbering | Accounting/legal | Product | Open |

## C. Security, privacy and compliance

| # | Question | Why it matters | How to resolve | Owner | Status |
|---|---|---|---|---|---|
| C1 | What is the threat model for a restaurant device? | PIN strength, kiosk exit, sync trust | Security review + interviews | Eng | Open |
| C2 | Is a 4–8 digit PIN acceptable, or is a longer secret required? | Hashing choice and UX | Product + security | Product | Open |
| C3 | Can we use a memory-hard KDF in the SDK, or a keychain pepper? | PIN brute-force resistance | Spike the SDK crypto surface | Eng | Open |
| C4 | How should failed logins be throttled without locking out a rush? | Security vs service | Product + security | Product | Open |
| C5 | What personal data is stored (customer phone/email), and for how long? | Privacy obligations | Legal review | Product | Open |
| C6 | Is data required to stay on-device, or may it sync/backup off-device? | Sync and cloud design | Customer/legal | Product | Open |
| C7 | How are devices paired and trusted on the LAN? | Sync security | Design + spike | Eng | Open |
| C8 | Are kiosk actions required to be attributable to a person? | Audit and RBAC | Interviews + legal | Product | Open |
| C9 | What is the secret-management story for OAuth and cloud backup? | v1 had a hardcoded secret issue | Security review; `fx.credentials*` | Eng | Open |
| C10 | What audit events must be retained (voids, discounts, price changes, logins)? | Compliance tables | Accountant/legal | Product | Open |
| C11 | Does the app need code signing/notarisation in every target market? | Release | Release engineering | Eng | Open |
| C12 | Is there a data-deletion/export request obligation? | Privacy | Legal | Product | Open |

## D. Sync

| # | Question | Why it matters | How to resolve | Owner | Status |
|---|---|---|---|---|---|
| D1 | Is the op-log + sidecar architecture acceptable? | It gates Phase 6 | Review ADR-0009 | Product/Eng | Open |
| D2 | Which tables and columns sync? | Scope and conflict surface | Data model review | Eng | Open |
| D3 | Is LWW acceptable, or must concurrent field edits merge? | Data loss vs complexity | Product decision | Product | Open |
| D4 | How are deletes represented? | Convergence correctness | Design | Eng | Open |
| D5 | How long are ops retained, and when is compaction safe? | Database growth and restore | Design + load test | Eng | Open |
| D6 | Does a single-device install run the sidecar? | Simplicity vs one code path | Design | Eng | Open |
| D7 | Must v2 interoperate with the Flutter app during rollout? | Protocol compatibility | Product rollout plan | Product | Open |
| D8 | Is a cloud relay ever required? | Architecture | Product strategy | Product | Open |
| D9 | Who is the host, and what happens when it leaves? | Availability | Design + test | Eng | Open |
| D10 | What happens after a restore from backup with an old clock? | Correctness | Design + test | Eng | Open |
| D11 | How does a new device bootstrap: full snapshot or replay? | Time to join, data size | Design | Eng | Open |
| D12 | Are there regulatory constraints on LAN traffic? | Security | Legal/IT review | Product | Open |

## E. Printing and hardware

| # | Question | Why it matters | How to resolve | Owner | Status |
|---|---|---|---|---|---|
| E1 | Is BLE required, or will LAN printers suffice? | ADR-0008 and market fit | Customer interviews + sales | Product | Open |
| E2 | Which exact printer models must work? | Test matrix and code pages | Customer hardware audit | Product | Open |
| E3 | Which receipt fields are legally required? | Layout and compliance | Legal review | Product | Open |
| E4 | Does the kitchen need one KOT per station? | Routing and duplicate paper | Kitchen interview | Product | Open |
| E5 | Is a cash drawer attached, and how is it opened? | Hardware integration | Customer audit | Product | Open |
| E6 | Are scanners keyboard-wedge or driver-based? | Input design | Hardware audit | Eng | Open |
| E7 | Is there a card terminal integration? | Payment scope | Product/partners | Product | Open |
| E8 | What should happen when the printer is offline? | Sale blocking vs warning | Product decision | Product | Open |
| E9 | How are reprints and duplicates prevented? | Idempotency design | Design | Eng | Open |
| E10 | What languages/code pages must print correctly? | Encoding | Target market review | Product | Open |
| E11 | Is a logo required on receipts? | Raster printing | Customer input | Product | Open |

## F. UX, accessibility and internationalisation

| # | Question | Why it matters | How to resolve | Owner | Status |
|---|---|---|---|---|---|
| F1 | Is a tablet/touch build in scope? | Layout and interaction design | Product decision (ADR-0011) | Product | Open |
| F2 | What are the real breakpoints for a restaurant counter? | Responsive layout | Store measurements | Design | Open |
| F3 | Does the counter need keyboard shortcuts? | Speed at rush | Shadowing | Design | Open |
| F4 | What is the kiosk exit gesture, and who may use it? | Security and support | Product + security | Product | Open |
| F5 | Are there accessibility requirements (contrast, target size, screen reader)? | Legal and usability | Audit + legal | Design | Open |
| F6 | Is the UI localised, or English-only? | Text, layout, printing code pages | Product | Product | Open |
| F7 | Which currency symbols and formats must render? | Money formatting | Target market review | Design | Open |
| F8 | What is the right empty/error/loading copy voice? | Operator trust | Copy review | Design | Open |
| F9 | Does the brand require the 11 menu-tile colours? | Theme decision | Design sign-off | Design | Open |
| F10 | Is dark mode a product requirement or a bonus? | Already implemented; needs validation | Product | Product | Open |
| F11 | How should a long menu be browsed on a small screen? | POS layout | Design | Design | Open |

## G. Platform, packaging and operations

| # | Question | Why it matters | How to resolve | Owner | Status |
|---|---|---|---|---|---|
| G1 | Which platforms ship first? | Packaging and testing | Product | Product | Open |
| G2 | How is the app distributed (direct, store, MDM)? | Signing, updates, support | Business decision | Product | Open |
| G3 | Is there an update mechanism, and who controls it? | Security and support | Design | Eng | Open |
| G4 | What does support need to diagnose a device? | Logs, diagnostics, DB inspector | Support interviews | Product | Open |
| G5 | What is the rollback plan? | Risk | Release design | Eng | Open |
| G6 | Does the app need to run offline indefinitely? | Cache, setup, printing, sync | Product | Product | Open |
| G7 | What are the minimum OS versions? | SDK support matrix | SDK docs + product | Eng | Open |
| G8 | Are there hardware/OS constraints in target restaurants (old machines, no Metal)? | GPU backend and performance | Customer audit | Eng | Open |
| G9 | How is the database stored and protected on disk? | Privacy and tamper resistance | Security review | Eng | Open |
| G10 | Is there a licence/subscription enforcement requirement? | `subscription` table is unused | Product | Product | Open |

## H. Scale and performance

| # | Question | Why it matters | How to resolve | Owner | Status |
|---|---|---|---|---|---|
| H1 | What is the largest realistic menu/table/order set? | Fixed buffers, paging, node budget | Customer data | Eng | Open |
| H2 | How long may a KDS run before a restart? | Memory, timers, logs | Soak test | Eng | Open |
| H3 | How fast must a sale be from tap to committed order? | UX target | Shadowing + measurement | Product | Open |
| H4 | What is the acceptable sync latency? | Sync design | Product | Product | Open |
| H5 | How many devices per restaurant? | Sync and host election | Customer data | Product | Open |
| H6 | What is the largest report window? | Query design and paging | Product | Eng | Open |
| H7 | Does the app need to handle a 10k-item catalog? | Virtualization and bump capacity | Customer data | Eng | Open |
| H8 | What happens at 1024 nodes on the POS? | UI failure mode | Automation measurement | Eng | Open |

## I. Team, process and docs

| # | Question | Why it matters | How to resolve | Owner | Status |
|---|---|---|---|---|---|
| I1 | Who owns each ADR and each phase? | Unmanaged risks | Assign owners | Lead | Open |
| I2 | What is the release cadence and versioning policy? | Packaging | Team decision | Lead | Open |
| I3 | Is the Flutter app frozen, or will it keep changing? | Oracle drift | Team decision | Lead | Open |
| I4 | Who is the product owner for edge cases (tax, refunds, sync)? | Decisions stall without one | Assign | Lead | Open |
| I5 | How do we keep these docs current? | Drift | Docs rules + review | Lead | Open |
| I6 | Is there a design partner restaurant for the pilot? | Unknown unknowns need reality | Recruit | Product | Open |
| I7 | What is the support model for v1 customers during cutover? | Trust | Plan | Product | Open |

## J. Unknown unknowns

These are areas where we do not yet know the right question. They are
listed so the team treats them as discovery work, not as solved.

| Area | Why we are blind | First move |
|---|---|---|
| **The rush** | No one has watched a real service at peak with v2. Timing, interruptions and workarounds are invisible in code. | Shadow a lunch and dinner service; time each step. |
| **Hardware reality** | No target printer, drawer, scanner or card terminal has been tested. | Buy the three most common devices; run a hardware day. |
| **Legacy data reality** | We have not inspected real customer databases. | Collect anonymised copies; profile every column. |
| **Tax and legal** | Rules vary by jurisdiction and change; v1 may be wrong. | Accountant and legal review; a per-market checklist. |
| **Multi-device behaviour** | Sync has never run in v2; human behaviour around conflicts is unknown. | Prototype fake-transport convergence, then a two-device pilot. |
| **Failure behaviour** | No one knows how staff react to a printer/DB/network failure mid-service. | Failure injection in a pilot; observe recovery. |
| **Accessibility** | No audit has been done; the SDK's a11y surface is not fully known. | Screen-reader and keyboard pass; contrast audit. |
| **Localisation** | The product may need languages and code pages we have not tested. | Market review; print a receipt in each language. |
| **Performance at scale** | Capacities are guesses; no fixture has 500 products or 10k orders. | Build large fixtures; measure nodes, memory, query time. |
| **Operator setup** | No real operator has installed v2 from scratch. | Usability test the setup flow on a clean machine. |
| **Support** | We do not know what a support call sounds like for v2 failure modes. | Interview support; design diagnostics from tickets. |
| **Security adversary** | The threat model is assumed, not observed. | Security review with a realistic device-access scenario. |
| **Data retention** | No one has asked customers how long they keep history. | Customer interviews + legal. |
| **The upgrade moment** | Cutover from v1 has never been rehearsed. | Dry-run on a real database and a real device. |
| **Pricing/licensing** | The `subscription` table exists with no product rule. | Product strategy. |

## Answered questions (kept for history)

| Question | Answer | Evidence |
|---|---|---|
| Should we rewrite or port Flutter? | Rewrite on the Native SDK in Zig | ADR-0001 |
| Should the app own a router? | No; navigation is model state | ADR-0003 |
| Should money be REAL? | No; integer minor units | ADR-0006, test |
| Should we keep `libeaterystore`? | No; engine-owned SQLite | ADR-0005 |
| Can the app speak WebSocket? | No; transport moves to a sidecar (proposed) | ADR-0009 |
| Can the app speak BLE/ESC-POS? | No; print sidecar (proposed) | ADR-0008 |
| Should we port Lottie/custom paint? | No; markup only | ADR-0010 |
| Should the schema be STRICT? | Yes; required by the SDK and better | ADR-0005 |
| Is there a pie chart? | No; use bar/stacked bar | ADR-0010 |

## Adding a question

1. Put it in the category where the decision will be made.
2. State why it matters in one sentence.
3. Name the method that will answer it.
4. Give it an owner.
5. If it blocks a phase, link the phase and do not start the phase.
6. When answered, move it to the history table with the evidence.
