# 00 — MASTER SPEC v2

Supersedes the v1 spec set (01–10) where they conflict. v1 specs 01, 03, 04, 05, 07, 08 stand unchanged. This document defines what changed, what is new, and the order of work.

## 0.1 The cut rule
**Any feature that does not remove non-coaching work from a coach's or director's week is out of v1.**
This is the operational form of "make coaching the priority." It is a rule, not a slogan. Every PR description states which minutes it removes and from whose week. A PR that cannot answer is closed.
Parity with TeamSnap is a claim made in a sales call after the wedge is won. It is not a build target.

## 0.2 What changed since v1
| Decision | v1 | v2 |
|---|---|---|
| Client surfaces | Web + Flutter iOS | **Web only.** Flutter surface is retired. |
| Parent client | App install assumed | **Zero install.** SMS, email, magic links, ICS. |
| Coach/director client | Native app | Installable PWA, one URL, agent-first |
| Push to parents | Web/native push | SMS and email only |
| Product shape | SaaS with AI features | Automation software: the agent does the work, the canvas proves it |

**Retire the Flutter surface explicitly.** Delete it, record the decision in `docs/decisions/`, and remove it from every readiness document. A half-built mobile client left in the tree corrupts every future audit.

## 0.3 Ground truth as of this spec (verified against the repo)
- 50 migration files. Tables exist for `programs`, `sessions`, `teams`, `team_athletes`, `athletes`, `guardians`, `guardian_links`, `obligations`, `installments`, `waiver_documents`, `waiver_signatures`, `staff_certifications`, `outbound_messages`, `delivery_events`, `agent_findings`, `agent_proposals`, `org_connectors`, `payment_event_ledger`.
- **`sessions` is not a schedule.** It holds `start_date`, `start_time text`, `end_time text`, `address text`, `assigned_member_id`. Times are text. There is no recurrence, no exception model, no RSVP, no attendance, no conflict detection, no timezone correctness, no ICS emission.
- **Zero matches** across all migrations for: `rsvp`, `recurr`, `registration`, `discount`, `magic_link`, `twilio`.
- `outbound_messages` exists and has never held a delivered row.
- Marketplace shape persists: `providers`, `bookings`, `sessions.program_id`.
Every spec below states its current state from this inventory, not from memory.

## 0.4 Gate ladder v2
Ordered. Work below an open gate is off the critical path and must be labelled as such in the PR description.
**G1 — SCHEMA RECONSTRUCTABLE.** A clean clone stands up an equivalent database. Ledger matches the repo; no hand-applied production object is missing. *Evidence: fresh project from migrations passes the smoke suite.*
**G2 — TRUST INTEGRITY.** Every claim the UI makes renders from verified server state. The background-check badge is the known one; the audit found 36 claim families. *Evidence: a claim register where every row cites the column it reads.*
**G3 — MONEY MOVES LIVE.** One live `acct_`, one live `ch_`, one live `re_`, one decline, ledger reconciled to zero drift. The webhook silent-200 is a gate failure, not a bug near one. *Evidence: Stripe dashboard plus a reconciliation query returning zero rows.*
**G4 — MINORS' DATA.** RLS proof, guardian consent, enforceable waiver signature, export and deletion. *Evidence: a cross-tenant read test suite that fails closed.*
**G5 — A MESSAGE REACHES A HUMAN.** One delivered email with a provider message id, mail-tester ≥ 9, a proven bounce path, one delivered SMS with a delivery receipt. *Evidence: provider ids and a `delivery_events` row per channel.*
**G6 — WRITES ARE SAFE.** Every agent write path declares precondition, inverse, and receipt. A silent no-op write fails loudly. *Evidence: the write registry is complete and CI enforces it.*
**G7 — THE SCHEDULE EXISTS.** Recurring events, availability, attendance, conflicts, cancellation, ICS. *Evidence: spec 12 acceptance suite green.*
**G8 — A PARENT SUCCEEDS WITH ZERO INSTALLS.** A parent who has never heard of Sporv completes registration, payment, waiver, and an RSVP on a phone with no app and no account. *Evidence: a timed, recorded run with a real stranger.*
**G9 — THE LOOP RUNS.** One real org, four consecutive weeks: schedule published, availability collected, attendance taken, reminders delivered, dues collected, founder does not touch the database. *Evidence: a four-week activity export.*
**G10 — MIGRATION UNDER AN HOUR.** Roster, schedule, and outstanding balances move from TeamSnap, SportsEngine, or Sports Connect in under 60 minutes of staff time. *Evidence: a timed run against a real export.*
G9 is launch. G10 is distribution. G8 is the one that makes replacement sellable and it did not exist in v1.

## 0.5 Implementation order
```
11 WEB-SURFACE ──────────┐
12 SCHEDULING ───────────┼── 13 PARENT-ZERO-INSTALL ── 17 MIGRATION
14 REGISTRATION ─────────┘
15 AGENT-AUTOMATION ── gates all agent work, start immediately, parallel
16 COMPLIANCE ── parallel, blocks G4 and any real org
18 RELIABILITY-COMMERCIAL ── blocks the first paid contract, not the first build
```
The single highest-value block is **12 — SCHEDULING**. The product is called a management system and has no schedule. Without it a parent has no reason to open anything more than once a month, and the agent has almost nothing to automate.

## 0.6 Conventions
**Migrations.** `supabase/migrations/2026MMDD_00NNNN_snake_name.sql`, continuing from `20260910_001046`. One concern per file. Every file idempotent.
**Time.** All instants are `timestamptz`. All wall-clock intent is stored as a local time plus an IANA timezone on the owning org or facility. Never `text`. Fixing `sessions.start_time` is a required migration, not a cleanup.
**Money.** Integer minor units. Never float. Every movement appends to `payment_event_ledger`. No exceptions, including refunds and credits.
**Writes.** Every write declares `precondition`, `inverse`, `receipt`. A write that reports success without changing rows is a CI failure.
**Definition of done.** Every spec section ends with a DoD. A DoD names the test file. A DoD without a test file is not a DoD.
**Tenancy.** Every table carries `organization_id`. Every RLS policy is proven by a test that asserts a second org reads zero rows.
