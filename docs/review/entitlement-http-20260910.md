# Entitlement capacity HTTP evidence

Date:2026-09-10. Supporting evidence for P1.03, not launch acceptance.
Business-gate verdict: NOTHING MOVED; isolated tests support G1/G4 only.
No production database, customer token, Stripe object or email was touched.

## What actually executed

PR399 source57312ce272a356448d83b1e1d38a0cccab0b3ea4.
Pinned PostgreSQL17.11 and PostgREST14.18 on loopback-only disposable CI.
The existing capacity guard SQL is loaded unchanged, then exercised through
HTTP with signed JWTs; an invalid signature is actually rejected by PostgREST.

The fixture is deliberately narrow: six table shapes, synthetic owner-only
RLS and a simplified assignment resolver. It does not replay every production
migration or prove trial expiry. It must not be counted as the full tenancy
or full catalog/guard integration audit.

Actual [HTTP job103068867105](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34536384825/job/103068867105):
```text
HTTP402 member_cap {"limit":15,"reason":"member_cap","current":15,"upgrade_to":"solo","current_plan":"free"}
HTTP402 group_cap {"limit":1,"reason":"group_cap","current":1,"upgrade_to":"solo","current_plan":"free"}
HTTP402 admin_cap {"limit":1,"reason":"admin_cap","current":1,"upgrade_to":"organization","current_plan":"free"}
PASS valid owner JWT: sixteenth member HTTP402; stored member count stays15
PASS owner JWT: three fixture table cross-org reads empty; cross-org insert403 without entitlement leakage
PASS real JWT validation: invalid signature401; staff write403
PASS other owner's entitled HTTP insert201 while both Free requests are observed blocked
PASS two observed concurrent HTTP database sessions: final slot yields one201, one402, total15
KNOWN GAP: raw table endpoint wraps reason/current_plan/upgrade_to/limit/current in details; application endpoint top-level payload is not proven
SUPPORTING PASS: actual guard SQL + JWT HTTP + fixture-only owner RLS; not production or full P1.03 acceptance
```

Concurrency is observed, not inferred from Promise.all: a separate controller
holds the actual provider advisory lock, pg_stat_activity must show both HTTP
database sessions waiting for that lock, and an independent owner's HTTP insert
must complete before the controller releases the lock.

At the same source commit, isolated SQL run34536384822 (11 jobs),
pr-checks34536384842 and secret-scan34536384823 all concluded success.

## Failed attempts retained

Initial HTTP workflow run34535833212 failed before creating any jobs.
The job-level env incorrectly referenced job.services; moving PGPORT into
the consuming step env maps fixed workflow validation. Actual run34536153681
then passed the initial HTTP cases, but its Promise.all final-slot check alone
was not treated as observed concurrency; the stronger run above supersedes it.

## Open acceptance gaps

- PostgREST maps PT402 to HTTP402 but wraps the required five fields in
  the standard error body's details string. Callers still need the reviewed
  application response contract; no top-level payload acceptance is claimed.
- Real production RLS, all org-scoped tables, guardians and actual staff roles
  are not covered by these owner-only fixture policies.
- These tests do not cover Gmail, draft/send/Ask quotas or module-route gates.
- The full catalog/resolver and capacity guards need a combined fixture and
  production parity verification; the narrow resolver stub is explicit.
- Deployment needs independent critical-path review, compatible caller rollout
  and live verification. Supabase OAuth failures currently block production
  reads. No migration was applied.
