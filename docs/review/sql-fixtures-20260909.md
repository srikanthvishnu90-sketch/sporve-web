# Isolated database verification — September 9, 2026

G4 supporting evidence only. **No launch gate or complete prompt is passed.**
These are disposable PostgreSQL fixtures, not production Supabase verification,
live Stripe acceptance, or delivery to a real family.

## Executed revision

- Draft review: [PR 399](https://github.com/srikanthvishnu90-sketch/sporve-web/pull/399).
- Commit: `d5c004d8438d68214749a7cc17da5144e4759b9e`.
- [SQL run 34397512370](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512370): **8/8 jobs success**.
- [Existing PR checks 34397512328](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512328): smoke and security-regressions success.
- Server: `PostgreSQL 17.11 (Debian 17.11-1.pgdg12+2) on x86_64-pc-linux-gnu`.
- Every job used a fresh cluster and role catalog. No Supabase host, production
  database, external provider credential, or live payment was used.
- The branch contains review-draft SQL and test infrastructure only; the local
  application/Edge Function changes are NOT covered by its successful smoke.

## Pasted execution evidence

Each link opens the exact job. Output excerpts omit runner setup and unrelated
container shutdown logs; assertions ran with `psql -X -v ON_ERROR_STOP=1`.

| Fixture | Job | Result |
| --- | --- | --- |
| Entitlement catalog | [102620753729](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512370/job/102620753729) | success |
| AI quota | [102620753674](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512370/job/102620753674) | success |
| Entitlement guards | [102620753442](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512370/job/102620753442) | success |
| Platform billing | [102620753946](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512370/job/102620753946) | success |
| Billing checkout | [102620753795](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512370/job/102620753795) | success |
| Agent entitlements | [102620753787](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512370/job/102620753787) | success |
| Approved inbox / shared send quota | [102620753790](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512370/job/102620753790) | success |
| Trigger grants | [102620753752](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397512370/job/102620753752) | success |

```text
plan-entitlements.test.sql:136: NOTICE: PASS: catalog, prices, legacy preservation, data-only edits, no-card trial and expiry
plan-entitlements.test.sql:152: NOTICE: PASS: owner read, cross-org denial, self-upgrade denial
plan-entitlements.test.sql:161: NOTICE: PASS: active staff read and inactive membership denial
entitlement-ai-quota.test.sql:104: NOTICE: PASS: missing usage receipt fails loudly
platform-billing.test.sql:217: NOTICE: PASS: platform projection, immutable duplicate receipts, malformed/null rejection, customer-bound duplicate, fail-closed unknown price, dunning, cancellation, CAS stale-snapshot conflict and service receipt denial
platform-billing.test.sql:258: NOTICE: PASS: invoice finding suppression rolls back entitlement and receipt
platform-billing.test.sql:379: NOTICE: PASS: retired subscription receipts preserve current assignment, duplicate identity, finding and authorization boundaries
platform-billing-checkout.test.sql:63: NOTICE: PASS: customer mode, tenant identity, request replay, one pending subscription, activation receipt and paid expiry denial
platform-billing-checkout.test.sql:87: NOTICE: PASS: missing activation receipt rolls back authorization and revision
parent-update-send.test.sql:142: NOTICE: PASS silent no-op rolls back notification and quota
parent-update-send.test.sql:237: NOTICE: PASS queued email reserves but never claims delivery; replay and next approval402
parent-update-send.test.sql:286: NOTICE: PASS worker inbox shared quota, stable approval/body and receipt replay
parent-update-send.test.sql:315: NOTICE: PASS worker cannot approve, edit, borrow actor/org or change the claimed family
parent-update-send.test.sql:362: NOTICE: PASS worker refuses a transaction that changes the original human approval
parent-update-send.test.sql:379: NOTICE: PASS worker shared quota denial and service-only RPC grants
trigger-function-grants.test.sql:111: NOTICE: PASS: exact revokes, PUBLIC removal, unaffected RPCs and pinned ledger path
trigger-function-grants.test.sql:122: NOTICE: PASS: normal authenticated DML still invokes the attached trigger
trigger-function-grants.test.sql:136: NOTICE: PASS: event trigger remains attached and executes
trigger-function-grants.test.sql:160: NOTICE: PASS: owner and all API roles denied UPDATE/DELETE; original row unchanged
```

The entitlement-guards job ends successfully after its assertion blocks; it
does not emit named PASS notices. The agent fixture passes its current
hard-stop behavior, which does NOT resolve the owner's contradictory request
for visible overflow drafts. Some older notice labels still say Individual,
Enterprise or unlimited Ask; catalog values and executable assertions, not
those labels, determine coverage. This is not metered Ask implementation.

## Harness issues found and fixed

Local `initdb` still failed with `shmget(... size=56 ...): Operation not
permitted` even with both shared-memory types set to mmap. No local server
started and initdb removed its incomplete data directory. The isolated CI
service is the alternative test environment; no production database was used.

Initial commit `e587e2da7175246fa64d6302e0009db909fdae68` failed workflow
validation before SQL execution because the dynamic service port used `job`
context at job-level `env`. Moving that binding to step-level `env` fixed it;
[GitHub's context table](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability)
documents the distinction. YAML parsing alone had not caught this error.

The successful run's health probe used the container default user and logged
`role "root" does not exist`; SQL connected as the intended postgres user and
passed. The next revision explicitly health-checks `-U postgres -d postgres`.

## Executed concurrency revision

Commit `682a83cf3b528c4be71a56d391669f2c1bdddced` adds observed, genuinely
concurrent psql sessions for duplicate approved-draft delivery, last Free slot,
another org completing while the first is locked, and a committed downgrade
while a sender waits. It also updates the old Solo 500-send fixture to unlimited
and explicitly enables PL/pgSQL assertions in CI.

[SQL run 34397849194](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397849194)
finished **8/8 success**. The concurrency step in
[job 102621902138](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397849194/job/102621902138)
also finished success. It observes two active database sessions waiting on locks
before release; these are not sequential replay tests or database doubles.

```text
2026-09-09T19:54:49.2627830Z NOTICE: PASS Solo has no monthly send cap beyond 500 and no Free footer
2026-09-09T19:54:49.9311882Z PASS same approved draft: two observed concurrent sessions, one notification, one quota acceptance, same receipt
2026-09-09T19:54:50.4045485Z PASS last Free slot: two observed concurrent sessions, one send, one exact402; other organization completes independently
2026-09-09T19:54:50.7027841Z PASS downgrade while sender waits: current Free entitlement blocks delivery without altering the approved draft
```

The same revision's [PR checks](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397849200)
passed smoke and security-regressions; [secret scan](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34397849205)
passed gitleaks. This verifies the test-only branch, NOT the separate dirty
application tree or production deployment. Local syntax, YAML parse, price
snapshot drift and `git diff --check` also exit0.

Required local `bash src/smoke.sh` was retried at14:56 Chicago time: exit1,
Chromium SIGTRAP / kill EPERM before browser assertions. This is still a
release blocker for the separate local application tree, not a failed SQL
assertion and not evidence of a production outage.

## Remaining release conditions

No merge, production migration, application cutover or deployment occurred.
Independent critical-path review, production schema compatibility, email-worker
integration, reserved-claim rollover/downgrade semantics, durable quota findings,
real multi-admin authorization, Stripe test-mode lifecycle/Portal acceptance,
confirmed prices and complete browser journeys remain open. The concurrency
harness uses two sessions for one approved owner identity; it cannot prove that
two distinct admins are authorized. The 5,000-org load test and four whole-system
concurrency cases from Prompt 3 remain separate requirements.
