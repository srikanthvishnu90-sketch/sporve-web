# 0.2 — Apply plan for the 39 unapplied migrations

Ground pass, 2026-08-11. Read-only against
`/Users/vishnusrikanth/SportsMan-main/supabase/migrations/`. No `supabase`
command was run, no database was contacted, nothing was committed.

Scope: the 42 files dated after `20260725033343`, minus the three now applied
(`20260726_000000_booking_member_org_guard`, `20260728_000203_coppa_gate`,
`20260728_000000_universal_bgcheck_gate`). 39 files.

---

## 0. The finding that reorders everything: a blocker OUTSIDE the 39

**`public.services`, `public.availability` and `public.set_updated_at()` are
created by `20260626_000000_services_availability.sql`, which is UNAPPLIED and
is NOT in the 39-file scope.**

`20260626_000000_services_availability.sql:41` creates `services`, `:69` creates
`availability`, `:96` creates `set_updated_at()`. Nothing in the 39 creates any
of them — `20260729_000100_services_availability_locations.sql:93` *alters*
`services`, it does not create it.

**19 of the 39 hard-depend on those three objects.** They cannot be applied in
any order without first applying a file the brief did not list. That file is
dated *before* the production ledger cutoff, so "everything before the cutoff is
applied" is false: the prod ledger has 19 entries against ~31 pre-cutoff files.

`20260626` also carries the `USING (true)` defect
(`20260626_000000_services_availability.sql:151-153`,
`availability_select_public ... for select to authenticated using (true)`).
Applying it alone opens that hole. It must be applied **in the same transaction
window** as `20260729_000100`, which closes it.

Call this **WAVE 0**. It is a prerequisite, not part of the 39.

---

## 1. Wave-ordered apply sequence

A wave depends only on production plus waves below it. Files inside a wave can
be applied together.

### WAVE 0 — prerequisite, out of scope
| file | provides |
|---|---|
| `20260626_000000_services_availability.sql` | `services`, `availability`, `set_updated_at()` |

Ships a `USING (true)` policy. **Never apply alone.** Pair with `20260729_000100`.

### WAVE 1 — depends on production only, no caveats → **the safe leading wave**
1. `20260728_000001_north_star_metrics.sql`
2. `20260728_000201_availability_truthfulness.sql`
3. `20260728_000202_resolution_center.sql`
4. `20260728_000300_waitlist.sql`
5. `20260728_000400_coach_invites.sql`
6. `20260728_000600_coach_policies.sql`
7. `20260801_000100_coach_agent_turns.sql`

Justification per file in §2.

### WAVE 2 — depends on production only, but each carries a caveat
| file | prod deps | caveat |
|---|---|---|
| `20260728_000100_recurring_bookings.sql` | programs, sessions, bookings, athletes, providers, organization_members | adds a BEFORE INSERT/UPDATE trigger to the live `bookings` write path (`:191`) |
| `20260728_000700_ai_drafts.sql` | messages, conversations | **replaces three live `messages` policies** (`:95`, `:113`, `:132`) |
| `20260728_000401_referrals.sql` | profiles, bookings | seeds an unblessed money value — `parent_session_credit_cents = 2500` (`:43-45`) |
| `20260729_000500_commission_rates.sql` | organization_members, bookings, `is_org_admin` | adds a commission-snapshot trigger to `bookings` (`:214`) — money path |
| `20260728_000101_platform_fees.sql` | bookings, programs, sessions | RED: the table `stripe-create-checkout` reads. See §3 |
| `20260802_000104_fix_refund_stranding_reconciliation.sql` | payment_event_ledger, bookings | RED: rewrites `apply_stripe_booking_event` |
| `20260728_000200_reviews.sql` | reviews, bookings, profiles, programs | **LOSSY** — hides every existing public review. See §3 |

### WAVE 3 — depends on Waves 1–2
| file | requires |
|---|---|
| `20260728_000701_draft_reply_trigger.sql` | `messages.status` / `.visible_to_parent` ← `000700` |
| `20260728_000702_resolve_draft_rpc.sql` | `draft_feedback` ← `000700` |
| `20260729_000510_trainer_affiliation.sql` | `coach_invites` ← `000400` |
| `20260729_000300_coach_invoices.sql` | `platform_fees` ← `000101` — **do not apply as written**, §3 |
| `20260801_000303_scale_append_only_tuning.sql` | `coach_agent_turns` ← `20260801_000100` |

### WAVE 4 — requires WAVE 0
| file | requires |
|---|---|
| `20260729_000100_services_availability_locations.sql` | `services`, `availability`, `set_updated_at()` |
| `20260728_000500_recurring_slots.sql` | `set_updated_at()` (`:107`). Self-deprecated by `000100:34-38` |

### WAVE 5 — the pivot
| file | provides |
|---|---|
| `20260729_000200_group_seats.sql` | `bookings.service_id`, `.slot_date`, `.slot_time` |

Nine later files reference these columns. Nothing else can proceed past here.

### WAVE 6 — requires `services` + `bookings.service_id`
- `20260729_000201_recurring_on_service.sql` (← `recurring_bookings`)
- `20260729_000202_credit_packs.sql` (← `booking_credits`)
- `20260729_000600_venue_resource_layer.sql` (← `locations`)
- `20260729_000610_org_services.sql` (provides `service_assignable_members`)
- `20260729_000700_camps.sql`
- `20260729_000900_team_blocks.sql` (← `set_updated_at`)

### WAVE 7
- `20260729_000620_shared_inbox.sql` (← `000610` + `000700` ai_drafts)
- `20260729_000701_camp_roster.sql` (← `000700` camps + `000610` + `set_updated_at`)
- `20260729_000800_waitlist_offers.sql` (← `program_waitlist` + `services`)
- `20260802_000101_fix_camp_roster_staff_bgcheck.sql` (← `000701`)

### WAVE 8 — the two landmines, plus P2
- `20260802_000102_fix_booking_update_freeze_service_id.sql` — **must not run before Wave 5**
- `20260802_000103_fix_booking_slot_capacity_trigger.sql` — **must not run before Wave 5**
- `20260802_000105_fix_p2_hardening.sql` — destructive, §3
- `20260801_000200_provider_media_storage.sql` — **do not apply as written**, §3

### WAVE 9 — performance, dead last
1. `20260801_000301_scale_query_indexes.sql` (← services, availability, locations, recurring_slots, program_waitlist)
2. `20260801_000300_scale_fk_indexes.sql` (← 13 tables from Waves 1–7)
3. `20260801_000302_scale_rls_initplan.sql` — **absolutely last**; it walks
   `pg_policy` and `ALTER POLICY`s every predicate in `public`. Run it before
   the policies exist and it silently skips them.

Total: 7 + 7 + 5 + 2 + 1 + 6 + 4 + 4 + 3 = **39**.

---

## 2. The safe leading wave — per-file justification

Criteria: (a) applies cleanly against production as it stands tonight, (b) drops
or replaces nothing production relies on, (c) depends on no unapplied file.

**1. `20260728_000001_north_star_metrics.sql`**
`:19-22` adds three *nullable* `timestamptz` columns to `providers` — no
default, no NOT NULL, so the 23 existing rows are untouched and the file says so
in a comment (`:17` "better honest-null than a fabricated now()"). `:109` and
`:142` `drop view if exists` two views that do not exist in prod — no-ops. Views
read only `bookings`, `programs`, `sessions`. Two new triggers, both new names,
neither replacing an existing one.
*Caveat, stated not hidden:* `trg_stamp_provider_first_booking` (`:100`) is an
AFTER trigger on `bookings`. It only stamps `providers.first_booking_at`; if it
raised, a booking insert would roll back. Verify one booking insert after apply.

**2. `20260728_000201_availability_truthfulness.sql`**
`:28-30` adds `last_active_at` (nullable) and `instant_book_enabled boolean not
null default false` — a default satisfies all 23 rows immediately. `:34`
backfills `last_active_at = created_at`, a 23-row UPDATE, honest and reversible.
`:41` adds `bookings.provider_responded_at`, nullable. `:19` states explicitly it
does not touch `provider_safety_cleared`, `match_eligible` or `search_candidates`
— verified: no reference to any of them outside comments.
*Caveat:* `trg_stamp_booking_provider_response` (`:74`) is a BEFORE trigger on
`bookings`. Same verification as above.

**3. `20260728_000202_resolution_center.sql`**
Creates `disputes` (`:43`) and nothing else. Its only external dependency is
`tg_touch_updated_at()` (`:85`), which production already has — it backs
`trg_org_members_touch` on `organization_members`. All triggers and policies are
on `disputes`. No existing object is touched.

**4. `20260728_000300_waitlist.sql`**
Creates `program_waitlist` (`:37`). FKs to `programs`, `providers`, `profiles`,
`athletes` — all present. Adds `is_program_provider_owner(uuid)` (new name) and
one trigger on the new table. Nothing existing is redefined.

**5. `20260728_000400_coach_invites.sql`**
Creates `coach_invites` (`:42`). FKs resolve to `providers`, `profiles`,
`bookings`. `redeem_coach_invite` and `is_coach_brought_family` are new names.
Note it is *later replaced* by `20260729_000510` (Wave 3) — that is a forward
supersession, not a conflict.

**6. `20260728_000600_coach_policies.sql`**
The smallest file in the set, 77 lines, no triggers, no policies, no functions.
`:36-40` adds five columns to `providers`. The only constraint is
`providers_faq_is_array` (`:50-52`) — and `faq` is added as `not null default
'[]'::jsonb`, so every pre-existing row is backfilled with a valid empty array
before the CHECK is evaluated. **Cannot fail on existing data.**

**7. `20260801_000100_coach_agent_turns.sql`**
Creates `coach_agent_turns` (`:37`) and nothing else. One trigger and three
policies, all on the new table. `is_org_admin()` is present in prod.

**Deliberately excluded from the leading wave, and why:**
`20260728_000100_recurring_bookings` and `20260729_000500_commission_rates` both
install triggers on the live `bookings` insert path, and `000500`'s writes a
money field. `20260728_000700_ai_drafts` replaces three live `messages` policies.
`20260728_000401_referrals` seeds a $25 credit nobody approved. None of these
*fail*; all four change live behaviour, which fails criterion (b). A file I am
not certain about does not belong in the wave whose purpose is certainty.

---

## 3. Do not apply as written

### 3.1 `20260728_000101_platform_fees.sql` — **the brief's premise is stale, but a real defect remains**

The brief says this file "seeds 18%/4%". **It does not, any more.** It was
rewritten on 2026-08-11 (`:20-34` documents the rewrite) and now seeds
`first_booking = 1200` and `recurring = 1200` — flat 12% both ways
(`:45-49`). That half of the concern is closed.

Two things are still wrong:

- **`:96` — `return coalesce(v_bps, 1800);`** The fail-safe fallback still
  returns **1800 bps (18%)**. If either row is missing or renamed, the function
  that `stripe-create-checkout` reads returns 18%, silently, on a live charge.
  The rewrite changed the seed and forgot the constant. Change to `1200`.
- **`:100-108` — the VERIFY block still asserts `-> first_booking 1800,
  recurring 400`.** Anyone following the file's own runbook after applying it
  will conclude the apply failed. Comment-only, but it is the instruction the
  next operator reads.

Money path → RED. Draft the two-line change, human applies.

### 3.2 `20260729_000300_coach_invoices.sql` — **a new instance of the shape the brief asked me to look for**

`:36-42` drops `platform_fees_fee_kind_check` and re-adds it widened to include
`'offplatform'`. `:45-49` then inserts **`('offplatform', 250, ...)` — a 2.5%
off-platform SaaS rate.**

`20260728_000101:22-25` records the owner's settled decision verbatim: *"a FLAT
12% on every booking … **no off-platform SaaS rate**, and no sliding scale …
final and should never change whatsoever."*

This file reintroduces exactly the thing that decision removed, into exactly the
table checkout reads, three files later in the sequence. It is the same failure
mode as the original 18/4 seed and it survived the 2026-08-11 rewrite because
the rewrite only edited `000101`. **The `platform_fees` block (`:28-49`) must be
deleted before this file is applied.** The rest of the file — `coach_contacts`,
`coach_invoices` — is unaffected and fine.

### 3.3 `20260801_000200_provider_media_storage.sql` — unconditional anon read

`:53-57`:

```sql
create policy provider_media_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'provider-media');
```

No `provider_safety_cleared`, no `status = 'approved'`, no path scoping. Any
anonymous caller reads every object any coach ever uploaded — including a coach
who was rejected, suspended, or never verified. The bucket is also created
`public = true` (`:39-41`), so the CDN serves it regardless of the policy.

Confirms the prod inventory's note (`0-2-prod-inventory.md:191-195`):
`storage.buckets` is **empty**, so this is authored-not-live and nothing is
exposed today. Gate the read on `provider_safety_cleared` off the path's first
segment before applying.

### 3.4 `20260728_000200_reviews.sql` — LOSSY on live public data

`:312-318` replaces `reviews_select_published` — a policy production currently
relies on (`0-2-prod-inventory.md:21`) — adding `published_at is not null`.
`published_at` is a column this same file adds at `:44`, so **every existing
review has it NULL**. There is no backfill. The instant this applies, every
currently-public review disappears from every anon and authenticated read.

Also on this file: `:51-53` adds `reviews_body_length check (body is null or
char_length(body) <= 4000)`, validated against existing rows. Prod's review count
is small; a 4000-character review is implausible but not impossible — check
before applying, it is one query.

The double-blind design is correct. It just needs a backfill in the same
transaction: `update public.reviews set published_at = created_at where
booking_id is null and published_at is null;` — i.e. legacy program reviews stay
published, new booking reviews use the window.

### 3.5 `20260802_000105_fix_p2_hardening.sql` — destructive, and it weakens a live invariant

Two separate problems.

**(a) `:146` — `drop policy if exists conversations_insert_participant on
public.conversations;`** with no replacement. That policy comes from
`20260623_000000_baseline.sql` and **is live in production**. After this, no
client can insert a conversation row directly; creation goes only through
`ensure_provider_conversation()` (`:151`). If any Flutter call site still does
`from('conversations').insert(...)`, messaging breaks silently for every user.
That call-site audit has not been done and is not in this document's scope.

**(b) `:119-133` — `prevent_profile_role_change` gains
`if auth.uid() is null then return new; end if;`.** Production's current version
(`20260723_000009_identity_safety_invariants.sql:3-14`) has **no such
exemption** — it raises on any role change, including one made with the service
role. This file removes that. Fourteen edge functions hold the service-role key;
after this, any of them can rewrite any user's role and the trigger named
`profiles_role_immutable` will not stop it. The file frames this as allowing "a
role CORRECTION". That may well be the intent, but it is a genuine reduction in
a live auth invariant and belongs to the owner, not to a migration run.

Auth path → RED. Findings only.

### 3.6 `20260728_000401_referrals.sql` — an unblessed money constant

`:43-45` seeds `parent_session_credit_cents = 2500`. A $25 two-way referral
credit is a pricing decision, and I found no record of the owner making it. Not a
defect in the SQL; a decision embedded in a migration. Confirm the number before
applying.

---

## 4. Gate-reversion audit — exhaustive

Every file in the 39 that redefines an object the two gates applied tonight
touch. **None of them reverts either gate.** Each is checked below.

| file:line | object redefined | preserves the gate? | evidence |
|---|---|---|---|
| `20260729_000200_group_seats.sql:65` | `enforce_booking_provider_verified` | **YES — strengthens** | Adds a `service_id → services.provider_id` resolution branch (`:80-85`), keeps the fail-closed `if v_provider is null then raise` (`:88`), keeps `if not public.provider_safety_cleared(v_provider) then raise` (`:91`). Trigger binding left alone (`:99`). The new branch closes a bypass: without it, a service-only booking would have had no resolvable provider. |
| `20260729_000610_org_services.sql:115` | `enforce_booking_member_org` | **YES — extends** | Same three-step shape as the applied `20260726_000000:23-55`; adds a `service_id` branch (`:128-130`); keeps the fail-closed `raise` (`:134-135`) and the roster-membership check (`:137-141`). Trigger re-bound with `service_id` added to the `UPDATE OF` list (`:150`) — a widening, not a narrowing. |
| `20260729_000510_trainer_affiliation.sql:51` | `enforce_org_member` | **YES — preserves verbatim** | `:66-71` reproduces the background-check clause exactly: `if tg_op = 'INSERT' then new.background_check_status := 'none'` / `elsif ... is distinct from old ... raise 'background_check_status is server-controlled'`. Additions are `affiliation_status` handling, GUC-gated to `respond_to_affiliation`. |
| `20260802_000102_fix_booking_update_freeze_service_id.sql:33` | `enforce_booking_provider_update` | **YES — strengthens** | All fifteen frozen columns from the prod version are present (`:49-67`), plus `service_id`, `slot_date`, `slot_time`. The status state machine (`:71-86`) and the cancellation-metadata rule (`:87-90`) are unchanged. **But see §5.1 — it breaks production if applied early.** |
| `20260802_000101_fix_camp_roster_staff_bgcheck.sql:36` | `camp_staff_can_access` | **YES** | Redefines a function created by `20260729_000701:53`, both unapplied. No live object involved. |
| `20260729_000100_services_availability_locations.sql:341` | `availability_select_public` | **YES — this is the fix, not the reversal** | See §5.4. |
| `20260729_000620_shared_inbox.sql:169` | `messages_select_participant` | **YES — extends correctly** | See §5.5. |
| `20260728_000700_ai_drafts.sql:95` | `messages_select_participant` | **N/A — creates the draft rule** | This is the file the brief credits. It replaces prod's baseline participant policy with one that adds `messages.visible_to_parent = true` on the parent branch. |
| `20260802_000105_fix_p2_hardening.sql:119` | `prevent_profile_role_change` | **NO — weakens** | See §3.5(b). Not one of the two gates named in the brief, but the same class of object and a live invariant. |
| `20260801_000302_scale_rls_initplan.sql:49-128` | **every policy in `public`** | **YES — by construction** | It never authors a predicate. It reads `pg_get_expr(p.polqual, p.polrelid)` from the catalog (`:63`) and performs one substitution, `auth.uid()` → `(select auth.uid())` (`:85`). `auth.uid()` is STABLE within a statement, so the value is identical. Gate predicates that call `provider_safety_cleared(...)` contain no `auth.uid()` and are never touched (`:106` only ALTERs when something changed). This is the correct design, and the safest possible way to do a bulk policy rewrite. |

**Not touched by any of the 39:** `provider_safety_cleared`,
`providers_select_public`, `programs_select_public`, `search_candidates`,
`enforce_provider_trust`, `enforce_athlete_consent`,
`enforce_booking_athlete_consent`, `athletes_consent_required`. Grepped across
all 39 — every hit is a comment or a call, never a `create or replace` / `drop`.
`20260728_000201:19` states this as an explicit intent; verified true.

One interaction worth recording, because it is the gates working as designed:
`20260729_000900_team_blocks.sql:484-486` inserts into `public.athletes` and
supplies `parent_consent = true` and `consent_version` explicitly, satisfying
`athletes_consent_required` (`20260728_000203:22-28`) and the consent trigger.
It does not bypass them. `:512-527` inserts bookings directly so the applied
`enforce_booking_provider_verified` and `enforce_booking_athlete_consent`
triggers both fire. Correct.

---

## 5. Files that would FAIL, or worse, silently break production

### 5.1 The two landmines — apply cleanly, then break every booking write

These are the most dangerous files in the set, because they **do not fail at
apply time.** PL/pgSQL resolves record fields and table names at *execution*,
not at `CREATE FUNCTION`. Both install a trigger on `bookings` with no `UPDATE
OF` column list, so trigger creation validates nothing.

| file | trigger installed | what happens |
|---|---|---|
| `20260802_000102:96` | `trg_enforce_booking_provider_update` BEFORE UPDATE on `bookings` | body reads `new.service_id`, `new.slot_date`, `new.slot_time` (`:54-56`). Column absent → **every booking UPDATE raises `record "new" has no field "service_id"`**. Cancellation, confirmation, decline, payment settlement: all dead. |
| `20260802_000103:90` | `trg_enforce_booking_slot_capacity` BEFORE INSERT OR UPDATE on `bookings` | body reads `new.service_id` (`:45`) and queries `public.services` (`:58`). **Every booking INSERT and UPDATE raises.** |

Both replace or add a trigger that production's booking flow runs on every
write. `000102` additionally `drop trigger if exists` the *working* prod trigger
first (`:95`), so there is no fallback. **Neither may be applied before Wave 5.**

Contrast with `20260729_000610:150`, which puts `service_id` in the trigger's
`UPDATE OF` list — that one fails loudly at apply time, which is the good
outcome.

### 5.2 Hard failures at apply — 19 files

Every one references a relation that neither production nor an earlier wave
provides. `ALTER TABLE`, `CREATE INDEX`, `CREATE TRIGGER ... EXECUTE FUNCTION`
and FK clauses all resolve at parse time, so these abort immediately.

**Missing `services` / `availability` (needs Wave 0):**
`20260729_000100` (`:93` `alter table public.services`, `:341` `drop policy ...
on public.availability`) · `20260729_000200` (`:45` FK to `services(id)`) ·
`20260729_000201` · `20260729_000202` · `20260729_000600` · `20260729_000610` ·
`20260729_000620` (`:49` FK) · `20260729_000700` · `20260729_000701` ·
`20260729_000800` · `20260729_000900` · `20260801_000301` (`:48` index on
`services`)

**Missing `set_updated_at()` (needs Wave 0):**
`20260728_000500` (`:107`) · `20260729_000701` (`:111`) · `20260729_000900`
(`:110`, `:195`, `:229`) — `CREATE TRIGGER` resolves the function at creation.
Note `tg_touch_updated_at()` (used by `20260728_000202:85`) **is** in prod, from
`20260708`; the two are easy to confuse and only one is available.

**Missing tables created by Waves 1–3:**
`20260728_000701` / `20260728_000702` (← `000700`) · `20260729_000510`
(`:40 alter table public.coach_invites` ← `000400`) · `20260801_000303`
(`:69 alter table public.coach_agent_turns` ← `20260801_000100`) ·
`20260801_000300` — needs thirteen absent tables: `booking_credits`,
`camp_roster`, `coach_invites`, `commission_rates`, `disputes`,
`program_waitlist`, `recurring_bookings`, `referral_credits`, `review_windows`,
`split_pay_links`, `team_block_members`, `team_blocks`, `waitlist_offers`.

`20260729_000300` is a partial case: its `platform_fees` block is wrapped in
`do $$ ... exception when undefined_table then null` (`:29-43`), so it degrades
to a no-op rather than failing — but then `:45` inserts into `platform_fees`
*outside* the block and fails hard.

### 5.3 Checked and clean

- `20260801_000300:59` indexes `plan_proposals(service_id)`. That column exists —
  `20260722_000000_outcome_first_data_model.sql:127`, `service_id uuid references
  public.programs(id)`. It is not the new `services` table. **Not a failure.**
- `20260801_000303` targets `messages`, `notifications`, `outbound_messages`,
  `payment_event_ledger`, `ai_audit_log`, `bookings` — all present — plus
  `coach_agent_turns`, which is its one dependency.
- `20260728_000700:44` adds `messages.status`. Verified against
  `20260623_000000_baseline.sql:181-187`: `messages` has only `id`,
  `conversation_id`, `sender_id`, `body`, `created_at`. No name collision, and
  `default 'sent'` satisfies `messages_status_check` for every existing row.
- `20260728_000600`'s `faq` CHECK cannot fail — the column arrives with
  `not null default '[]'::jsonb`.
- `20260802_000104` and `20260802_000105` define the same
  `apply_stripe_booking_event` signature. Diffed: the bodies are functionally
  identical; `000105` only hardens `search_path` from `public` to `''`. Apply
  `000104` first (it also adds `flag_stranded_payment_events` and
  `alert_stranded_payment_events`, which `000105` does not), then `000105`.

### 5.4 The brief's second premise is inverted

The brief lists `20260729_000100_services_availability_locations` as suspect for
"rewriting `availability_select_public`, previously flagged as `USING (true)`."

It rewrites it **to fix it.** The `USING (true)` lives in
`20260626_000000_services_availability.sql:151-153`. `20260729_000100:341-350`
replaces it with:

```sql
create policy availability_select_public on public.availability
  for select to anon, authenticated
  using (public.provider_safety_cleared(provider_id));
drop policy if exists availability_select_owner on public.availability;
create policy availability_select_owner on public.availability
  for select to authenticated using (
    exists (select 1 from public.providers pv
            where pv.id = availability.provider_id and pv.owner_id = auth.uid()));
```

An unverified coach's schedule stops being world-readable; the coach keeps read
access to their own grid through the new owner policy. `:332-334` does the same
to `services_select_public`. **This is the remediation, and it must ship in the
same window as Wave 0 or the hole opens and stays open.**

### 5.5 The brief's third premise is half right

`20260729_000620_shared_inbox:169` does redefine `messages_select_participant`,
the policy `20260728_000700` created. It does **not** reverse the decision:

```sql
c.provider_id = auth.uid()                                   -- coach: all rows
or exists (select 1 from public.organization_members m       -- assigned trainer: all rows
           where m.id = c.assigned_member_id and m.member_user_id = auth.uid())
or (c.searcher_id = auth.uid() and messages.visible_to_parent = true)  -- parent: gated
```

The parent branch keeps `visible_to_parent = true` verbatim. The only change is a
third branch for the assigned trainer, who is coach-side. Sequencing still
matters — `000620` must run *after* `000700`, or `visible_to_parent` does not
exist and the policy fails to compile.

### 5.6 Destructive or lossy, ranked

| file:line | effect | prod impact at today's row counts |
|---|---|---|
| `20260728_000200:312` | `reviews_select_published` gains `published_at is not null` with no backfill | **Every existing public review goes dark.** Count unknown — the one row count not captured. Highest real data risk in the set. |
| `20260802_000105:146` | drops `conversations_insert_participant` (baseline policy, live) | Direct conversation inserts stop working. Blast radius = every messaging entry point in the Flutter client that does not call the RPC. Not audited. |
| `20260802_000105:119` | `prevent_profile_role_change` gains a service-role exemption | Weakens a live auth invariant across 40 users. §3.5(b). |
| `20260802_000102:95` | drops the working `trg_enforce_booking_provider_update` and installs one that cannot run | §5.1. |
| `20260729_000300:36-42` | drops and widens `platform_fees_fee_kind_check` | Harmless in isolation; the `insert` at `:45` that follows is not. §3.2. |
| `20260728_000700:95,113,132` | replaces three live `messages` policies | Net stricter. `messages_insert_sender` now requires `status='sent' and visible_to_parent=true`; both columns default to exactly those values, so an unmodified client insert still passes. Low risk, but it is a live policy swap. |
| `20260729_000800:64` | `alter table public.program_waitlist alter column program_id drop not null` | Zero — the table does not exist in prod yet and will be empty. |
| `20260728_000201:34` | `update public.providers set last_active_at = created_at` | 23 rows, a new column, honest value. Negligible. |
| `20260729_000100:125-133` | backfills `services.service_type` and `.capacity` | Only fills NULLs; `services` is empty in prod regardless. Zero. |
| `20260728_000200:51-53` | `reviews_body_length <= 4000` validated against existing rows | Almost certainly zero. One query confirms it. |
| `20260801_000303:61-89` | `alter table ... set (autovacuum_*)` on seven tables | Storage-parameter change only, instantly reversible. Zero data risk. |

### 5.7 Could not determine

- **How many reviews production holds, and whether any is public today.** That
  decides whether §3.4 is a cosmetic regression or a visible one. Not queryable
  from the repo, and the inventory's row-count query was blocked.
- **Whether any Flutter call site inserts into `conversations` directly.** That
  decides the blast radius of §3.5(a). Requires an `rg` pass over
  `~/SportsMan-main/lib`, which is outside this file's scope.
- **Whether `20260626_000000_services_availability.sql` is the only unapplied
  pre-cutoff file the 39 depend on.** I verified the three objects the 39 name.
  The prod ledger has 19 entries against ~31 pre-cutoff files, so roughly twelve
  are unapplied and I checked only the ones referenced by name. A full pre-cutoff
  reconciliation is a separate pass and should happen before any of Wave 4
  onward is attempted.
- **Whether `stripe-create-checkout` currently reads `platform_fees` or still
  reads `PLATFORM_FEE_BPS`.** `20260728_000101:15-17` claims the latter. If true,
  applying the table changes nothing until the edge function is redeployed —
  which changes how urgent §3.1 is. Not verified; that is an edge-function read,
  not a migration read.

---

## Five-sentence technical reading

**What changed:** nothing in either repository — this is a read-only
dependency-graph pass over 39 SQL files, and the only artifact is this document.
**The mechanism:** a migration is a transaction, and Postgres resolves object
references in two different places — `ALTER TABLE`, `CREATE INDEX`, foreign-key
clauses and a trigger's `UPDATE OF` column list are resolved at *parse* time and
fail loudly, whereas a name inside a PL/pgSQL function body (`new.service_id`,
`public.services`) is resolved at *execution* time, which is why
`20260802_000102` and `20260802_000103` install successfully and then raise on
every subsequent booking write. **What it touches downstream:** the ordering here
is the input to the actual apply run, and its load-bearing claim is that
`20260626_000000_services_availability.sql` — a file outside the stated scope —
gates nineteen of the thirty-nine, so any plan that starts at `20260728` stalls
at Wave 4. **What would break it:** a pre-cutoff migration I did not check being
unapplied and providing some other object the 39 assume (I verified only
`services`, `availability` and `set_updated_at()` by name), or production having
drifted since the inventory was captured tonight. **How it was verified:** `rg`
over the DDL statements of all 39 files to build the object graph, then full or
targeted reads of the fourteen files classified failing, destructive or
gate-touching, with each gate redefinition diffed line-by-line against the
version production currently runs.
