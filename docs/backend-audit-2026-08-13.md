# Full backend audit — prod Supabase `tseszaprvtvqrkfpditu` (2026-08-13)

Read-only. All statements below are `select` / introspection; nothing was applied.
Every "Fix SQL" block is a draft for the in-session agent / owner to review and
run by hand — none of it was executed by this monitor.

Ranked worst-first.

---

## 1 — P0. The safety badge is unbacked for every provider currently showing it, and the marketplace cannot take a single real payment

```sql
select
  count(*) filter (where status='approved' and background_check_status='verified') as safe,   -- 20
  count(*) filter (where stripe_charges_enabled)                                    as payable, -- 1
  count(*) filter (where status='approved' and background_check_status='verified'
                     and stripe_charges_enabled)                                    as both,     -- 0
  count(*) filter (where stripe_account_id is not null and not stripe_charges_enabled)
                                                                                    as connect_abandoned -- 1
from public.providers;
-- total_providers = 27 (23 approved, 4 pending)

select count(*) as verified_without_a_date
from public.providers
where background_check_status='verified' and background_check_completed_at is null;
-- = 20
```

**Measured now:** `safe = 20`, `verified_without_a_date = 20` — the sets are
**identical**. Every single provider that currently passes the public safety
gate (`status='approved' AND background_check_status='verified'`) has
`background_check_completed_at IS NULL` and `verified_at IS NULL` and
`stripe_account_id IS NULL`. Nobody ran a check. `both = 0` — not one provider
passes both the safety gate and the payment gate simultaneously, consistent
with `10` total bookings / `0` paid. The one provider with `stripe_charges_enabled`
is not in the safety-cleared set at all.

**Cost.** "Background-checked" is the product's core promise (CLAUDE.md /
`mod-safety.js:328` in the web sim). Right now it is asserted for 20 real
provider rows with zero evidence behind the claim — this is a live legal/
child-safety exposure, not a demo artifact, because these are the rows the
`providers_select_public` / `programs_select_public` RLS policies actually
serve to anon/authenticated callers today. Separately, the business cannot
process one real charge: no provider satisfies both gates, so `both=0`
explains why `paid_bookings=0` of `10` total bookings.

**Fix — not a SQL bug, a data-truth problem. Diagnostic + two remediation
options, draft only:**
```sql
-- Full list of currently-affected providers (20 rows)
select id, business_name, status, background_check_status,
       background_check_completed_at, verified_at, stripe_account_id
from public.providers
where background_check_status='verified' and background_check_completed_at is null;

-- Option A — if a real vendor check happened off-DB, backfill the true date
--   per provider (repeat per id, do not batch-guess a date):
-- update public.providers
--   set background_check_completed_at = '<actual vendor completion timestamp>'
--   where id = '<provider id>';

-- Option B — if no real check exists yet, the claim is false today; revert
--   the status so the public gate stops showing "verified" for nothing:
-- update public.providers
--   set background_check_status = 'pending'
--   where background_check_status='verified' and background_check_completed_at is null;
```
Both options are writes to a trust/safety column — RED tier, human-applied only.

---

## 2 — Cron health monitor has a blind spot: network-level timeouts vanish from ok / failed / pending, so success_pct reads 100% while calls are silently failing

```sql
select job_name, attempts_24h, ok, failed, pending, success_pct, last_attempt, latest_error
from public.cron_http_health;
-- lifecycle-process: attempts_24h=1440 ok=1421 failed=0 pending=3 success_pct=100.0
--   latest_error = "Timeout of 5000 ms reached. Total time: 5001.631000 ms ..."
```

The view (`pg_get_viewdef`) buckets by:
- `ok`: `status_code between 200 and 299`
- `failed`: `status_code is not null and (status_code < 200 or status_code >= 300)`
- `pending`: `checked_at is null`

A `pg_net` timeout writes a `cron_http_audit` row with `status_code = NULL`
**and `checked_at` already set** (verified against `check_cron_http_health()`'s
reconciliation logic, which copies `net._http_response.error_msg` into
`error_msg` and leaves `status_code` null on a timeout). That row satisfies
neither `failed` (needs `status_code IS NOT NULL`) nor `pending` (needs
`checked_at IS NULL`) — it disappears from the view entirely while
`success_pct`'s denominator (`count(*) filter (where status_code is not null)`)
also excludes it, so the percentage is computed only over the calls that got
*some* HTTP status, silently dropping the ones that got none.

**Measured now, `lifecycle-process`, last 24h:**
```sql
select count(*) total_24h,
  count(*) filter (where status_code between 200 and 299) ok,
  count(*) filter (where status_code is not null and status_code not between 200 and 299) failed,
  count(*) filter (where checked_at is null) pending,
  count(*) filter (where checked_at is not null and status_code is null) silently_dropped_timeout
from public.cron_http_audit
where queued_at > now() - interval '24 hours' and job_name='lifecycle-process';
-- total_24h=1440  ok=1421  failed=0  pending=3  silently_dropped_timeout=16
```
**16 of 1440 runs (1.1%) in the last 24h hit a real 5-second `pg_net` timeout
against `/functions/v1/lifecycle-process`** (reminder / rebook-nudge dispatch)
and are invisible to the monitoring view built specifically to catch this
class of failure — the same failure mode this project already shipped once
behind 63,321 green ticks (per the `check_cron_http_health()` function's own
in-code comment referencing that incident), now recurring at smaller scale on
the one job actually instrumented.

Also worth knowing, not a bug: 7 of the 8 active `cron.job` rows never write to
`cron_http_audit` at all — 6 are pure-SQL functions with no HTTP call
(`enqueue_reminders_24h`, `enqueue_rebook_nudges`, `release_due_reviews`,
`run_ai_data_retention`, `alert_production_invariants`, `check_cron_http_health`
itself), correctly absent. `plan-progress-sweep` (`invoke_plan_progress_sweep`)
*does* call `net.http_post` and log to the same table, but has **zero** rows
ever — consistent with zero `development_plans` currently matching its
`status in ('draft','active')` loop condition, i.e. unproven in prod rather
than broken.

**Fix SQL (draft, not applied) — count a checked-but-status-less row as failed:**
```sql
create or replace view public.cron_http_health as
select
  job_name,
  count(*) as attempts_24h,
  count(*) filter (where status_code between 200 and 299) as ok,
  count(*) filter (where checked_at is not null
                      and (status_code is null or status_code < 200 or status_code >= 300)) as failed,
  count(*) filter (where checked_at is null) as pending,
  round(100.0 * count(*) filter (where status_code between 200 and 299)::numeric
        / nullif(count(*) filter (where checked_at is not null), 0)::numeric, 1) as success_pct,
  max(queued_at) as last_attempt,
  (array_agg(error_msg order by queued_at desc) filter (where error_msg is not null))[1] as latest_error
from public.cron_http_audit
where queued_at > now() - interval '24 hours'
group by job_name;
```

---

## 3 — RLS scopes rows, not columns: `programs` lets the owning coach directly overwrite server-computed trust fields

`bookings` (`enforce_booking_provider_update`), `providers`
(`enforce_provider_trust`), `reviews` (`enforce_review_update` /
`enforce_review_authorship`), and `profiles` (`prevent_profile_role_change`)
all have a `BEFORE UPDATE` trigger that freezes their server-owned columns.
**`programs` does not.** Its only trigger, `enforce_program_assignment`, checks
only that `assigned_member_id` is a real roster member — nothing guards
`average_rating`, `total_reviews`, or `enrolled_count`, and the table's one
UPDATE policy checks ownership only:

```sql
-- programs_update_owner (verified via pg_policies):
-- USING/WITH CHECK: exists (select 1 from providers pv
--                            where pv.id = programs.provider_id and pv.owner_id = auth.uid())
```

Any authenticated coach who owns a program can currently run, through the
normal REST path:
```sql
update programs set average_rating = 5.0, total_reviews = 500, enrolled_count = 0
where id = '<own program id>';
```
and nothing in the database stops it. Verified this has **not** happened yet —
the review-aggregate cross-check below returns 0 disagreeing rows — but there
is zero server-side resistance if it did.

**Cost.** Rating fraud (self-inflating the one number families use to judge
trust) and enrolled-count tampering (hiding a sellout or fabricating scarcity),
both silent and both bypassing the review-aggregation trigger entirely since
that trigger only *recomputes* on `reviews` writes — it never re-asserts
`programs` state on a direct `programs` update.

**Fix SQL (draft, matches the existing `enforce_*_trust`/`_update` pattern):**
```sql
create or replace function public.enforce_program_owner_update()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null then return new; end if;
  if new.average_rating  is distinct from old.average_rating
   or new.total_reviews  is distinct from old.total_reviews
   or new.enrolled_count is distinct from old.enrolled_count then
    raise exception 'average_rating / total_reviews / enrolled_count are server-computed and cannot be self-set';
  end if;
  return new;
end;
$$;

create trigger trg_enforce_program_owner_update
before update on public.programs
for each row execute function public.enforce_program_owner_update();
```

**Tables checked and found clean (RLS + trigger together already close the
column gap):** `bookings`, `providers`, `reviews`, `profiles`. `athletes`
(`enforce_athlete_consent` guards consent fields only; remaining columns —
`first_name`, `skill_level`, `medical_conditions`, etc. — are ordinary
parent-owned data with no server-derived safety field to protect, so this is
not a finding). `sessions` has no column guard either, but its only
owner-editable fields are ordinary scheduling/capacity data with no
downstream trust signal — noted, not ranked as a finding.

---

## 4 — New since the last recorded sweep: `review_windows` is RLS-enabled with zero policies

```sql
select c.relname, c.relrowsecurity
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' and c.relrowsecurity
  and c.relname not in (select tablename from pg_policies where schemaname='public');
-- ai_feedback, review_windows, waitlist
```

`ai_feedback` and `waitlist` are known/standing (waitlist already tracked in
`docs/gaps.md` #15 as the likely reason signups silently drop — an `anon`
INSERT is denied at the DB with zero policies present). **`review_windows` is
new** — it did not exist at the 2026-08-07 pentest's list of 11 zero-policy
tables. RLS-on with no policy already denies all client access by default
(fail-closed, not a live hole), but it is not legible — nine sibling tables
(`ai_alert_thresholds`, `ai_audit_log`, `ai_observability_events`,
`cron_http_audit`, `edge_rate_limits`, `market_overrides`,
`market_readiness_config`, `payment_event_ledger`, `search_parse_cache`,
`waitlist_rate_limit`) already got an explicit `using (false)` deny-all policy
at some point since that pentest. `review_windows` should get the same
treatment for consistency, since it holds the double-blind review release
timer (`release_due_reviews()` reads it) and its intended access pattern is
service-role only.

**Fix SQL (draft, behavior-neutral — makes the existing fail-closed default explicit):**
```sql
create policy review_windows_no_client_access on public.review_windows
  for all to anon, authenticated using (false) with check (false);
```

---

## 5 — Migration drift is still growing, not shrinking: prod now has schema changes with no file anywhere in the repo

Prod's applied lineage (`list_migrations`) now runs through
`20260812173006_handle_new_user_reads_business_name` — 17 migrations past the
`20260725033343` high-water mark recorded in `docs/gaps.md` #1, so real
progress. But the newest entries expose the same untracked-SQL-editor pattern
that finding was originally about:

- `20260812164345_provider_media_storage` and
  `20260812173006_handle_new_user_reads_business_name` have **no matching file**
  anywhere under `~/SportsMan-main/supabase/migrations/` (checked, including
  `_archive/`) — `grep -rl` for both function-name fragments across the whole
  repo returns nothing.
- The one local file `20260812_000100_review_aggregates.sql` was applied to
  prod as **three** separately timestamped migrations
  (`review_aggregates_fn`, `review_aggregates_triggers`,
  `review_aggregates_match_column_scale`) — confirming the change was pushed
  in pieces via the SQL editor, not via the file as a single transaction.

**Cost.** The repo can no longer reconstruct current prod schema from its own
migration files. A fresh branch/staging rebuild from `supabase/migrations/`
would miss the `handle_new_user_reads_business_name` fix and the re-applied
`provider_media_storage` migration entirely — this is exactly the "repo/prod
lineage divergence" already logged in `docs/gaps.md` #1, with new evidence
that it is still accumulating.

**Fix.** Not a SQL fix — write the two missing changes back as numbered
migration files and commit them (`supabase migration new
handle_new_user_reads_business_name`, capture the live function body via
`pg_get_functiondef`, repeat for `provider_media_storage`). Flagged for the
owner; no file was created by this monitor.

---

## Checked and CLEAN (no finding — reported per instruction not to manufacture noise)

- **RLS disabled or `USING (true)`:** none. Every one of the 41 `public` tables
  has `relrowsecurity = true`; `select count(*) from pg_policies where
  qual='true'` style scan of all policy quals shows none is the bare literal
  `true` — every SELECT/UPDATE policy is keyed off `auth.uid()`, an
  ownership `exists(...)`, or an explicit `false` deny.
- **SECURITY DEFINER search_path:** all but 8 of ~71 definer functions pin
  `search_path=''` (the hardest setting). The 8 with a non-empty schema
  (`apply_stripe_booking_event`, `match_eligible`, `search_candidates`,
  `search_listings`, `search_relax`, `submit_ai_feedback`,
  `consume_edge_rate_limit`, `purge_expired_ai_observability`,
  `purge_expired_ai_feedback`, `run_ai_data_retention`) are the same set
  flagged in the 2026-08-07 pentest as "not exploitable on Supabase (anon/
  authenticated lack CREATE on public)" — standing, not new.
- **`rls_auto_enable` "anon can execute SECURITY DEFINER" advisor WARN:**
  reviewed the body — it `RETURNS event_trigger`, which Postgres refuses to
  invoke outside an actual DDL event trigger regardless of GRANTs. The
  advisor flag is a false positive for exploitability; calling
  `/rest/v1/rpc/rls_auto_enable` errors at the Postgres level. Not a finding.
- **`is_org_admin` anon-executable:** body only returns true when
  `auth.uid()` matches a real owner/admin row; `auth.uid()` is null for
  `anon`, so it always returns `false` for an unauthenticated caller. Safe by
  construction.
- **Denormalised counters vs source rows:**
  `review-aggregates` cross-check (rounded to 1 decimal, matching
  `average_rating numeric(2,1)`) returns **0 disagreeing rows** — confirms the
  `docs/gaps.md` "review aggregates pending" item is resolved and stayed
  resolved.
- **Orphans:** bookings with no session, sessions with no program, programs
  with no provider, athletes with no parent — all **0**.
- **Published programs with no future sessions:** **0**.
- **`background_check_completed_at` P0 (see finding #1 above for the real
  number):** the query itself is clean/working; the *data* is the finding.
- **Money moved but not landed** (paid booking, unpayable provider): **0
  rows** — but only because there are currently **0 paid bookings at all**
  (`10` total bookings, `0` paid), which is downstream of finding #1
  (`both=0`, nobody can be paid yet).

## Noted, not ranked as a finding

- **13 of 23 approved providers (57%) have zero published programs** —
  `approved_providers_no_published_programs = 13`. Real inventory gap for a
  family browsing, but consistent with a pre-launch seed state rather than a
  bug; flagged for awareness, not remediation SQL.
- **`metro_key` function_search_path_mutable (WARN):** not `SECURITY DEFINER`,
  not granted to `anon`/`authenticated` — no exploit path. Low/informational,
  matches prior standing note.
- **Advisor WARNs for extensions in `public` (`pg_net`, `vector`) and leaked
  password protection disabled:** both standing/known, unrelated to this
  session's schema changes, not re-litigated here.

---

## Summary

**5 findings, worst: every provider currently marked "background-check
verified" (20/20) has no completion date behind the claim, and zero providers
pass both the safety and payment gates simultaneously — the core trust
promise is unbacked and the marketplace cannot yet take a real payment.**
