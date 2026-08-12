# Sporve launch backlog

Every item is a checkbox. No dates, no week numbers — phases gate each other,
and a phase is done when its boxes are ticked.

Grounded against **production project `tseszaprvtvqrkfpditu`** on 2026-08-11 by
direct query, not inference. Findings that came from a static read of the repo
are marked `[static]`; findings confirmed against the live database are marked
`[prod]`.

Legend: `[RED]` = owner applies by hand, agent drafts only (RLS, Stripe, auth,
migrations, capacity, consent, secrets). `[Y]` = implement + PR, human merges.
`[G]` = agent ships it.

---

## What production actually is

| fact | value | source |
|---|---|---|
| tables in `public` | **36** | `[prod]` |
| RLS policies | **97** | `[prod]` |
| tables with RLS enabled | **36 of 36** | `[prod]` |
| migration ledger entries | **17**, last `20260725033343` | `[prod]` |
| migrations in `SportsMan-main` | **73** | `[static]` |
| migrations in `sporve-landing` | **8** | `[static]` |
| fee columns on `bookings` | **0** | `[prod]` |

**The central defect.** Production's migration ledger contains 17 entries, and
none of them are from `SportsMan-main`. Yet objects those migrations define —
`rls_auto_enable`, `is_org_admin`, `claim_provider_role`, `submit_safety_report`
— *do* exist in production. Both things are true because most of the schema was
applied **outside the migration system**, by hand in the SQL editor.

The consequence is not academic. `supabase db push` from `SportsMan-main` would
attempt to apply all 73 migrations, because the ledger says none have run. Many
create objects that already exist. The lineage is not "behind" — it is
**unrecorded**, which is a different and worse problem, because no tool can tell
you the delta.

Production also has **36 tables where the Flutter migration set describes ~65**.
Production is the older programs-model schema. The newer outcome-model work is
partly applied and partly not, and which is which is currently unknown.

---

## Phase 0 — stop the bleeding

Nothing else is safe until these are done. No feature work in parallel.

### 0.1 Deploy-target safety
- [x] `[G]` Unlink `sporve-landing` from prod (`supabase/.temp` → `.temp.unlinked-2026-08-11`)
- [ ] `[G]` Add `supabase/.temp/` to `.gitignore` in both repos if absent
- [ ] `[Y]` Decide the single repo that owns `supabase/migrations` for prod
- [ ] `[Y]` Decide the single repo that owns `supabase/functions` for prod
- [ ] `[Y]` Write `SUPABASE-OWNERSHIP.md` in both repos naming the owner and the rule
- [ ] `[Y]` Add a pre-push git hook in the non-owning repo that rejects `supabase db push`
- [ ] `[Y]` Add a pre-push hook rejecting `supabase functions deploy` in the non-owning repo
- [x] ~~`[RED]` Rotate the Supabase service-role key (it is in `.env` files in two repos)~~ — **this item was wrong.** No service-role key exists on disk in any of the three repos. Every one of the ~90 files matching `service_role` uses it as a Vault secret *name* or a `Deno.env.get()` lookup, e.g. `SportsMan-main/supabase/migrations/20260701_000000_lifecycle_process_cron.sql:39` reads it out of `vault.decrypted_secrets`. Verified independently with a regex requiring real three-segment JWT structure: **zero hits.** Nothing to rotate.
- [x] `[G]` Grep all three repos for committed secrets, and `git log -S` for any ever committed → `docs/launch/0-1-secrets-sweep.md`. **Zero credentials were ever committed to any repo.** Every pickaxe hit resolved to a placeholder (`sk-ant-xxxx…`), a scanner's own detection regex, prose in a doc, or — memorably — the Skia symbol `sk_test_bit` in `app/canvaskit/*.symbols`, which greps like a Stripe test key and is not one. `the-sporve-web` history is clean on every pattern.
- [x] `[G]` Confirm the `eyJ…` runs in `the-sporve-web/index.html:36` are base64 font bytes, not JWTs — they contain `+` and `/` and have no three-part structure. Recorded so the next sweep does not re-flag them.
- [ ] `[G]` **MEDIUM — the one real finding.** `SportsMan-main/.gitignore` ignores only two literal paths: `env.json` and `supabase/functions/.env`. Verified with `git check-ignore`: a root-level `.env`, `.env.local`, `.env.production`, or a `.env` inside any *new* edge-function directory would be swept up by `git add -A` silently. Nothing has leaked — this is a trap that has not sprung. Two-line fix, deferred only to avoid disturbing a running auditor.
- [ ] `[RED]` Rotate the Anthropic API key — pasted in plaintext in a chat session. **Still the only genuine credential exposure found.**
- [ ] `[RED]` Set a $25/mo spend cap on a **separate** Anthropic workspace (org-wide would kill `ai-gateway`)

### 0.2 Recover what exists only in production
- [x] `[G]` `pg_get_functiondef` → `claim_provider_role()` — **recovered**, saved to `docs/launch/prod-recovered-functions.sql`
- [x] `[G]` `pg_get_functiondef` → `claim_organization_role()` — **recovered**, same file
- [x] `[G]` Also recovered `prevent_profile_role_change` and `handle_new_user` (needed to judge the first two)
- [x] `[G]` **Verified the escalation is safe.** `claim_provider_role` sets a transaction-local flag `sporve.role_claim`, and `prevent_profile_role_change` honours it *only* for `searcher → provider` on `id = auth.uid()`. A client cannot set that flag — `set_config` lives in `pg_catalog`, which PostgREST does not expose as `/rpc/`. Both functions set `search_path TO ''`, closing the classic SECURITY DEFINER shadowing attack. The Dart comment claiming self-promotion-only was **correct**.
- [ ] `[Y]` **NEW D1** — `handle_new_user` swallows every exception and returns `new`. A failed profile insert still creates the `auth.users` row, leaving a user who can authenticate but has no `profiles` row, fails every RLS policy keyed on it, and cannot self-repair. Query prod for orphans: `select count(*) from auth.users u left join public.profiles p on p.id=u.id where p.id is null;`
- [ ] `[Y]` **NEW D1b** — add a reconciliation job that repairs orphaned auth users
- [ ] `[Y]` **NEW D1c** — make the signup trigger fail loudly instead of silently
- [ ] `[G]` **NEW D2** — document that `prevent_profile_role_change` returns `new` (allows) when `auth.uid()` is null, so any of the 14 service-role-holding edge functions can silently rewrite any user's role. Intentional, but the name overstates the protection.
- [ ] `[Y]` **NEW D3** — `claim_organization_role` has no gate at all: any provider self-declares as an organization. Combined with `find_affiliatable_account` being org-admin gated, that is the account-existence oracle in 2.3. Fix the oracle, not this function.
- [x] `[G]` Dump all 97 live policies → `docs/launch/0-2-prod-inventory.md` §1–2. **No policy anywhere uses `USING (true)`.** All 83 authenticated policies resolve to one of five ownership shapes.
- [x] `[G]` Dump all 19 live triggers → same file §3
- [x] `[G]` **Verify the two policies that RLS alone would not make safe** → §4
  - `bookings_update_searcher` would let a parent set `payment_status='paid'`; `enforce_booking_provider_update` freezes 15 financial/identity columns and runs `status` through an explicit state machine. **Sound.**
  - `organization_members_update_self` would let a trainer mark themselves background-checked — the worst possible bug in this product; `enforce_org_member` forces `background_check_status := 'none'` on insert and raises on any end-user change. **Sound.**
- [x] `[G]` Record the systemic caveat → §5. Every guard short-circuits on `auth.uid() is null`, which is required for the background-check webhook but means **none of these triggers defend against a compromised edge function**. 14 functions hold the service-role key.
- [ ] `[G]` Query the `storage` schema for bucket policies — not covered by §1–5, `provider-media` still open
- [ ] `[RED]` Full `supabase db dump --schema public` → `00000000000000_prod_baseline.sql`
- [ ] `[RED]` Full `supabase db dump --data-only` of reference tables (sports, categories)
- [ ] `[G]` Commit all dumps to the owning repo — this is the first time prod is reproducible
- [ ] `[G]` Diff the recovered `claim_provider_role` against `prevent_profile_role_change` and document how it legally bypasses it
- [ ] `[G]` Record every prod object that appears in **no** migration file

### 0.3 Version-control hygiene
- [ ] `[G]` Commit `20260806000000_waitlist_role_allow_athlete.sql` — currently **untracked**, one `git clean` destroys it
- [ ] `[G]` Audit both repos for other untracked `.sql`
- [ ] `[G]` Resolve the byte-identical duplicate `20260726_000000_booking_member_org_guard.sql` across repos
- [ ] `[G]` Resolve the byte-identical duplicate `20260710_000000_session_trainer.sql` across repos
- [ ] `[G]` Resolve `enforce_booking_member_org()` being defined a **third** time in `20260729_000610_org_services.sql`
- [x] `[G]` Diff all 12 shared edge functions — **10 differ, and `sporve-landing` is larger in every one**

  | function | SportsMan-main | sporve-landing |
  |---|---|---|
  | `ai-gateway` | 344 | **1102** |
  | `chat-answer` | 128 | **467** |
  | `generate-embedding` | 117 | **430** |
  | `provider-onboard-draft` | 195 | **398** |
  | `session-note-summarize` | 157 | **355** |
  | `ai-match` | 190 | **311** |
  | `ai-chat` | 123 | **301** |
  | `chat-parse-query` | 134 | **205** |
  | `search-parse` | 175 | **183** |
  | `search-execute` | 137 | **165** |
  | `generate-proposals` | 298 | 298 |
  | `goal-formulate` | 147 | 147 |

  **This settles the ownership question for functions.** `sporve-landing` owns
  the AI/search edge functions — newer in all ten, and prod's migration ledger
  contains exactly its AI-observability tables (`ai_feedback`,
  `ai_observability_events`, `ai_alert_thresholds`). The `SportsMan-main`
  copies are stale stubs.

  *Correction: an earlier reading of this had the direction backwards
  (1102 in the app repo). Measured directly, it is the reverse.*

- [ ] `[Y]` Delete the 10 stale copies from `SportsMan-main/supabase/functions`
- [ ] `[Y]` Record in `SUPABASE-OWNERSHIP.md`: **landing owns edge functions**, app owns app schema
- [ ] `[G]` Confirm `generate-proposals` and `goal-formulate` are byte-identical, not merely same-length
- [ ] `[G]` For each function, record the deployed version vs the repo version

### 0.4 Environment
- [ ] `[owner]` Install Docker Desktop — blocks `db reset`, `db diff`, `db pull`
- [ ] `[owner]` Install Vercel CLI (`npm i -g vercel`) — unblocks `vercel env pull`, `vercel logs`
- [ ] `[G]` Verify `supabase --version` is current
- [ ] `[G]` Document the exact CLI versions that produced the baseline dump

---

## Phase 1 — the money is wrong `[CRITICAL-PATH]`

Six representations of the platform fee exist. **None is 12%.** The one on the
live charge path is **10%**.

### 1.1 Establish one source of truth
- [ ] `[owner]` Confirm in writing: flat 12%, coach-side deducted, no sliding scale, no separate SaaS fee
- [ ] `[RED]` Set `PLATFORM_FEE_BPS=1200` in Supabase Edge Function Secrets
- [ ] `[Y]` Remove the `?? 1000` default from `stripe-create-checkout/index.ts:49` — fail closed, never silently charge 10%
- [ ] `[Y]` Make the function refuse to start if `PLATFORM_FEE_BPS` is unset
- [ ] `[Y]` Narrow the sanity bound at `:161-163` from `0..3000` to `1200..1200` until a real sliding scale ships
- [ ] `[Y]` Delete `20260728_000101_platform_fees.sql`'s 18%/4% schedule
- [ ] `[Y]` Delete `resolve_platform_fee_bps` — 20 references, **0 callers**
- [ ] `[Y]` Remove all 20 stale references to it
- [ ] `[Y]` Rewrite `lib/core/utils/platform_fee.dart` to a single constant sourced from the server
- [ ] `[Y]` Delete the 2.5% "SaaS fee" from `20260729_000300_coach_invoices.sql:46`
- [ ] `[Y]` Delete the `?? 250` default in `coach-invoice-create/index.ts:147`
- [ ] `[Y]` Verify `commission.dart` still consumes rather than re-derives (its header says it does)

### 1.2 Record the fee on the booking
`bookings` has **zero** fee columns `[prod]`. Sporve's revenue exists only inside
Stripe. You cannot reconcile, audit, or answer a coach who disputes a payout.

- [ ] `[RED]` Migration: add `platform_fee_bps int`, `platform_fee_cents int`, `gross_cents int`, `net_to_provider_cents int` to `bookings`
- [ ] `[RED]` Backfill existing rows from Stripe's `application_fee` records
- [ ] `[Y]` Write all four on the webhook's paid branch, inside the existing idempotent RPC
- [ ] `[Y]` Add a check constraint: `platform_fee_cents = round(gross_cents * platform_fee_bps / 10000)`
- [ ] `[Y]` Add a check constraint: `gross_cents = platform_fee_cents + net_to_provider_cents`
- [ ] `[Y]` Freeze all four columns against `authenticated` in the update guard
- [ ] `[Y]` Build a daily reconciliation job: sum of `platform_fee_cents` vs Stripe's application-fee total
- [ ] `[Y]` Alert when they diverge by more than one cent

### 1.3 Fix what users are told
- [ ] `[Y]` `sporve-landing/terms.html:88` — "sliding 8–12%" → flat 12%. **This is live legal copy.**
- [ ] `[Y]` `provider_payouts_payments_screen.dart:18-20` — remove 18% and 4%
- [ ] `[Y]` `provider_finances_screen.dart:962` — remove "~2.5% SaaS fee"
- [ ] `[Y]` `provider_finances_screen.dart:1189` — same
- [ ] `[Y]` Remove the `provider_controller.dart:1010` comment admitting the code lies
- [ ] `[Y]` Audit every coach-facing screen for a hardcoded percentage
- [ ] `[Y]` Audit every parent-facing screen for a fee disclosure
- [ ] `[Y]` Confirm the coach's *net* is shown at booking time, not just gross
- [ ] `[Y]` Add a fee line to the parent's receipt
- [ ] `[Y]` Add a fee line to the coach's payout statement
- [ ] `[Y]` Add a smoke assertion: no literal `18`, `4`, `2.5`, `10` used as a fee percent anywhere

---

## Phase 2 — RLS and data exposure `[CRITICAL-PATH]`

### 2.1 The providers column leak `[prod-confirmed live]`

```sql
providers_select_public  USING (status = 'approved')  TO anon, authenticated
```

Row-scoped, **not column-scoped**. PostgREST lets the caller choose `select=`,
and the anon key is public by design. So any anonymous caller can request
`latitude`, `longitude`, `stripe_account_id`, and `owner_id` for every approved
coach. On an independent-coach marketplace, exact coordinates are frequently a
home address.

- [ ] `[RED]` Create `providers_public` view exposing only safe columns
- [ ] `[RED]` Set `security_invoker=true` on that view
- [ ] `[RED]` Revoke `select` on `public.providers` from `anon`
- [ ] `[RED]` Grant `select` on `providers_public` to `anon`
- [ ] `[Y]` Round `latitude`/`longitude` to ~1km in the public view, keep exact for the owner
- [ ] `[Y]` Add `search_radius_km` so coaches choose their own precision
- [ ] `[Y]` Repoint all nine `supabase_repository.dart` call sites to the view
- [ ] `[Y]` Repoint `search-execute` to the view
- [ ] `[Y]` Repoint `chat-answer`'s provider lookups
- [ ] `[Y]` Regression test: anon `select=stripe_account_id` returns 403, not data
- [ ] `[Y]` Regression test: anon `select=latitude` returns rounded, not exact
- [ ] `[Y]` Regression test: owner still reads their own exact coordinates
- [x] `[G]` Sweep every table with an `anon` policy for the same column-scope bug — **done against prod, and `providers` is the only one**

  All 14 live anon-facing policies, queried from `pg_policies`:

  | table | policy | `USING` | verdict |
  |---|---|---|---|
  | `providers` | `providers_select_public` | `status = 'approved'` | ⚠️ **the leak** — no column scope |
  | `programs` | `programs_select_public` | `status = 'published'` | ✅ intended, all columns public-safe |
  | `sessions` | `sessions_select_public` | parent program published | ✅ |
  | `reviews` | `reviews_select_published` | parent program published | ✅ |
  | `organization_members` | `organization_members_select_public` | verified bg-check **and** active **and** org approved **and** has a published program | ✅ careful work |
  | `ai_alert_thresholds` | `..._no_client_access` | `false` | ✅ locked |
  | `ai_audit_log` | `..._no_client_access` | `false` | ✅ locked |
  | `ai_observability_events` | `..._no_client_access` | `false` | ✅ locked |
  | `edge_rate_limits` | `..._no_client_access` | `false` | ✅ locked |
  | `market_overrides` | `..._no_client_access` | `false` | ✅ locked |
  | `market_readiness_config` | `..._no_client_access` | `false` | ✅ locked |
  | `payment_event_ledger` | `..._no_client_access` | `false` | ✅ locked |
  | `search_parse_cache` | `..._no_client_access` | `false` | ✅ locked |
  | `waitlist_rate_limit` | `..._no_client_access` | `false` | ✅ locked |

  Eight tables are explicitly `USING (false)` — deliberately locked, including
  `payment_event_ledger`. Four are gated on a published/approved parent.
  `organization_members` additionally requires `background_check_status =
  'verified'`, which is the safety property this product is sold on, enforced
  in the database rather than the client. **This is good work.** The exposure
  is one policy, not a pattern.

- [x] `[G]` Re-check `availability` — **`availability_select_public ... USING (true)` is NOT live in production.** It appears in the migration files but is absent from `pg_policies`, i.e. that migration was never applied. Struck from 2.3 below; keep it from ever being applied as written.

### 2.2 Storage — **not live, deferred**
- [x] `[G]` Audit every storage bucket policy — **`storage.buckets` is EMPTY in production. Zero buckets exist.**
- [x] `[G]` Confirm no bucket allows anon write — vacuously true; there are no buckets
- [x] ~~`[RED]` `provider-media` unconditional `anon` read~~ — **authored, not applied.** Not a live exposure. Media upload is not a working feature in prod.
- [ ] `[Y]` Before that migration is ever applied, fix the policy: signed URLs with a TTL, or unguessable path prefixes instead of `{uid}/...`
- [ ] `[Y]` Do not use `owner_id` as a storage path component — it is the same value 2.1 leaks

### 2.3 Policy correctness
- [x] ~~`[RED]` `availability_select_public ... USING (true)`~~ — **not live**; the migration defining it was never applied. Do not apply it as written.
- [ ] `[Y]` Rewrite that policy in the migration file before it ever ships
- [ ] `[RED]` `ai_feedback` has RLS enabled and **zero policies** `[prod advisor]`
- [ ] `[RED]` `waitlist` has RLS enabled and **zero policies** `[prod advisor]`
- [ ] `[RED]` `is_org_admin(uuid)` is `SECURITY DEFINER` and executable by **anon** `[prod advisor]`
- [ ] `[RED]` `rls_auto_enable()` is `SECURITY DEFINER` and executable by **anon** `[prod advisor]`
- [ ] `[RED]` Revoke `execute` from `anon` on both
- [ ] `[RED]` `find_affiliatable_account` is an account-existence oracle — anyone can self-serve `role='provider'` then become their own org admin
- [ ] `[Y]` Never use `is_org_member()` for `athletes`, `session_notes`, `parent_updates`, `messages`, `conversations` — key on the specific assignment, or a 50-trainer org becomes 50 readers of one child's notes
- [ ] `[G]` Enumerate all 97 live policies and classify each: correct / too broad / unknown
- [ ] `[G]` For each of 36 tables, write down who should read and who should write
- [ ] `[G]` Diff that intent against the live policy set
- [ ] `[Y]` Write an automated RLS test suite: one anon probe and one wrong-user probe per table
- [ ] `[Y]` Run it in CI against a local `db reset`

### 2.4 Edge function auth
- [ ] `[Y]` `session-note-summarize:214` authenticates the caller and checks **nothing else** — any account gets a polished parent-facing update about a named minor
- [ ] `[Y]` Add an assignment check: is this caller the coach for this athlete?
- [ ] `[Y]` `goal-formulate:106-107` — auth is `if (!authHeader)`; no `getUser()` in the file
- [ ] `[Y]` `generate-proposals:142,145` — two service-role reads before the ownership check at `:157`; reorder
- [ ] `[Y]` Add `verify_jwt=true` for `generate-proposals`, `goal-formulate`
- [ ] `[G]` Confirm all 14 functions call `auth.getUser()` and not merely check for a header
- [ ] `[G]` Document that `verify_jwt` proves nothing — the anon key **is** a valid project JWT
- [ ] `[Y]` Copy `search-execute`'s pattern (forward the user's JWT so RLS still governs) wherever a function reads user data

### 2.5 Waitlist abuse `[live on the marketing site today]`
- [ ] `[Y]` `join-waitlist:66-72` — captcha is **skipped entirely** when `HCAPTCHA_SECRET` is unset
- [ ] `[RED]` Set `HCAPTCHA_SECRET` in Supabase secrets
- [ ] `[Y]` Fail closed when it is missing, do not `return true`
- [ ] `[Y]` `join-waitlist:113-116` — rate limiter returns `true` on DB error. **Fails open.**
- [ ] `[Y]` Fail closed on rate-limit error
- [ ] `[Y]` `:155` — IP is read from client-supplied `x-forwarded-for`; trust only the platform's own header
- [ ] `[Y]` The function is an outbound-Gmail amplifier; add a global hourly ceiling
- [ ] `[Y]` Add alerting on waitlist signup volume

### 2.6 Auth config
- [ ] `[owner]` Enable leaked-password protection (HaveIBeenPwned) `[prod advisor]`
- [ ] `[owner]` Set minimum password length
- [ ] `[owner]` Review session/JWT expiry
- [ ] `[owner]` Confirm email confirmation is required
- [ ] `[RED]` Move `pg_net` out of the `public` schema `[prod advisor]`
- [ ] `[RED]` Move `vector` out of the `public` schema `[prod advisor]`
- [ ] `[RED]` Set an explicit `search_path` on `metro_key` `[prod advisor]`

---

## Phase 3 — booking integrity `[CRITICAL-PATH]`

### 3.1 Capacity
`20260802_000103:38-92` takes an advisory `hashtext` lock and counts before
rejecting — correct as far as it goes. But the seat is held at **booking
insert, before payment**, so two families can both hold the last seat.

- [ ] `[G]` Read the `v_taken` predicate at `:69-78` and confirm whether `expired` is excluded — **currently unverified**
- [ ] `[RED]` Add a `hold_expires_at` to unpaid bookings
- [ ] `[RED]` Exclude expired holds from the capacity count
- [ ] `[Y]` Background job to expire stale holds
- [ ] `[Y]` Release the hold on Stripe checkout expiry
- [ ] `[Y]` Release the hold on explicit cancellation
- [ ] `[Y]` Concurrency test: 20 simultaneous bookings for 1 seat → exactly 1 paid
- [ ] `[Y]` Concurrency test: expired hold frees the seat
- [ ] `[Y]` Test the advisory-lock path under a connection-pool restart

### 3.2 Stripe correctness
- [ ] `[G]` Confirm the webhook reads the raw body before HMAC — `stripe-webhook:86,99-109` says it does
- [ ] `[G]` Confirm `apply_stripe_booking_event` claims `stripe_event_id` before any money write — `20260723_000006:156-166`
- [ ] `[G]` Confirm the paid branch cross-checks amount and currency — `:175-177`
- [ ] `[Y]` Add a smoke test that replays a webhook twice and asserts one ledger row
- [ ] `[Y]` Add a test for an out-of-order webhook (paid before created)
- [ ] `[Y]` Add a test for a webhook with a tampered signature
- [ ] `[Y]` Handle `charge.refunded`
- [ ] `[Y]` Handle `charge.dispute.created`
- [ ] `[Y]` Handle `account.updated` (coach loses payout eligibility)
- [ ] `[Y]` Handle `payment_intent.payment_failed`
- [ ] `[RED]` Confirm Stripe Connect **Express** onboarding works end-to-end with a real coach
- [ ] `[RED]` Confirm payouts actually land in a connected account
- [ ] `[Y]` Block booking a coach whose `stripe_charges_enabled` is false
- [ ] `[Y]` Decide and implement the refund policy
- [ ] `[Y]` Decide who eats Stripe's fee on a refund
- [ ] `[Y]` Test the full flow in Stripe test mode, then once live with a $1 booking

---

## Phase 4 — schema convergence

Only possible after Docker is installed and the Phase 0 dumps exist.

- [ ] `[G]` `supabase db reset` locally from the owning repo's migrations
- [ ] `[G]` `supabase db diff` local vs the prod baseline dump
- [ ] `[G]` Enumerate every difference
- [ ] `[G]` For each: is prod right, or is the migration right?
- [ ] `[RED]` Write reconciling migrations for the differences where the migration is right
- [ ] `[RED]` Amend migrations where prod is right
- [ ] `[RED]` Repair the ledger so prod records what it actually has
- [ ] `[G]` Confirm a clean `db reset` now equals prod byte-for-byte on schema
- [ ] `[Y]` Add that equality check to CI
- [ ] `[G]` Determine which of the 36 prod tables the Flutter client queries but which the migrations do not create
- [ ] `[G]` Determine which tables the migrations create that prod lacks — the client will 404 on these
- [ ] `[Y]` Fix or remove every client query against a non-existent table
- [ ] `[Y]` Set up a staging Supabase project
- [ ] `[Y]` Prove a migration applies cleanly to staging before prod
- [ ] `[Y]` Write the rollback procedure and test it once

---

## Phase 5 — COPPA and consent `[CRITICAL-PATH]`

- [ ] `[G]` Determine whether `20260728_000203_coppa_gate.sql` is applied — it is **after** the last ledger entry `20260725033343`, so probably **not**
- [ ] `[RED]` Apply the consent gate if absent
- [ ] `[Y]` Verifiable parental consent before any athlete under 13 has a record
- [ ] `[Y]` Consent is recorded with timestamp, method, and the consenting adult
- [ ] `[Y]` No under-13 data collected before consent
- [ ] `[Y]` Parent can view everything held about their child
- [ ] `[Y]` Parent can delete everything held about their child
- [ ] `[Y]` Deletion actually cascades — test it
- [ ] `[Y]` Coach messaging to a minor routes through or copies the guardian
- [ ] `[Y]` No minor's exact location is ever exposed
- [ ] `[Y]` Photos/video of minors require separate explicit consent
- [ ] `[Y]` Confirm the universal background-check gate is applied and enforced
- [ ] `[Y]` A coach without a current check cannot be booked
- [ ] `[Y]` An org cannot mark its own trainers checked (`20260708_000000:99-115` says it can't — verify in prod)
- [ ] `[owner]` Legal review of the consent flow
- [ ] `[owner]` Privacy policy matches what the code does
- [ ] `[owner]` Terms match what the code does — see 1.3

---

## Phase 6 — operational readiness

- [ ] `[Y]` Error tracking on the Flutter client
- [ ] `[Y]` Error tracking on every edge function
- [ ] `[Y]` Alert on webhook failures
- [ ] `[Y]` Alert on payment failures
- [ ] `[Y]` Alert on RLS-denied spikes (a sign of a client bug or a probe)
- [ ] `[Y]` Structured logging with a request ID through the stack
- [ ] `[Y]` Confirm PITR is enabled on prod
- [ ] `[Y]` Test a restore into a scratch project
- [ ] `[Y]` Document the restore procedure
- [ ] `[Y]` Load-test search
- [ ] `[Y]` Load-test booking
- [ ] `[Y]` Review the performance advisors and add missing indexes
- [ ] `[Y]` Rate-limit every public edge function, failing closed
- [ ] `[Y]` A runbook for: payment stuck, double booking, coach can't onboard, data deletion request
- [ ] `[owner]` Decide the support channel and who answers it

---

## Standing rules for this backlog

1. A `[RED]` box is never ticked by an agent. Agent drafts the exact SQL or
   config change; owner applies it; agent verifies afterwards.
2. Every `[Y]` and `[G]` change goes through a branch and a PR (repo rule 11).
3. Nothing ships without the live verification the release contract requires.
4. When a box turns out to be wrong, strike it and say why — do not silently
   delete it. The wrong boxes are the record of what was learned.
