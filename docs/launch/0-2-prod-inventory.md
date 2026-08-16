# Production inventory — `tseszaprvtvqrkfpditu`

Captured 2026-08-11 by direct catalog query. This is the first written record of
what the live database actually contains, as opposed to what the migration files
claim it should contain.

**36 tables · 97 policies · RLS enabled on 36 of 36 · 19 triggers · ledger of 17
migrations ending `20260725033343`**

---

## 1. The anon surface — 14 policies

The only surface an unauthenticated caller can reach with the publishable key.

| table | policy | `USING` | verdict |
|---|---|---|---|
| `providers` | `providers_select_public` | `status = 'approved'` | ⚠️ **row-scoped, not column-scoped** |
| `programs` | `programs_select_public` | `status = 'published'` | ✅ |
| `sessions` | `sessions_select_public` | parent program published | ✅ |
| `reviews` | `reviews_select_published` | parent program published | ✅ |
| `organization_members` | `organization_members_select_public` | bg-check `verified` **and** `is_active` **and** org approved **and** org has a published program | ✅ four-way gate |
| `ai_alert_thresholds` | `_no_client_access` | `false` | ✅ locked |
| `ai_audit_log` | `_no_client_access` | `false` | ✅ locked |
| `ai_observability_events` | `_no_client_access` | `false` | ✅ locked |
| `edge_rate_limits` | `_no_client_access` | `false` | ✅ locked |
| `market_overrides` | `_no_client_access` | `false` | ✅ locked |
| `market_readiness_config` | `_no_client_access` | `false` | ✅ locked |
| `payment_event_ledger` | `_no_client_access` | `false` | ✅ locked |
| `search_parse_cache` | `_no_client_access` | `false` | ✅ locked |
| `waitlist_rate_limit` | `_no_client_access` | `false` | ✅ locked |

**One finding, not a pattern.** `providers_select_public` filters rows but says
nothing about columns, and PostgREST lets the caller choose `select=`. So an
anonymous caller can read `latitude`, `longitude`, `stripe_account_id` and
`owner_id` for every approved coach. Fix is backlog 2.1.

Everything else here is correct, and several are better than correct —
`organization_members` enforces the background-check requirement *in the
database* rather than trusting the client to filter.

---

## 2. The authenticated surface — 83 policies

Every policy resolves to one of five ownership shapes. No policy anywhere uses
`USING (true)`.

**Shape A — direct ownership (`col = auth.uid()`)**
`athletes` (parent_id) · `bookings` (searcher_id) · `notifications` (user_id) ·
`profiles` (id) · `providers` (owner_id) · `privacy_requests` (requester_id) ·
`refund_requests` (requester_id) · `reviews` (author_id) ·
`safety_reports` (reporter_id) · `organization_members` (member_user_id)

**Shape B — ownership one join away (via `providers.owner_id`)**
`programs` · `teams` · `session_notes` · `parent_updates` ·
`lifecycle_message_prefs` · `outbound_messages`

**Shape C — ownership two or three joins away**
`sessions` (→ programs → providers) · `bookings` provider-side (→ sessions →
programs → providers) · `team_athletes` (→ teams → providers) ·
`development_plans` (→ athlete_goals → athletes) · `plan_proposals` and
`progress_digests` (→ development_plans → athlete_goals → athletes) ·
`progress_digest_sources` (→ progress_digests → athletes)

**Shape D — participant membership**
`conversations` (`searcher_id` OR `provider_id`) ·
`messages` (via the parent conversation's participants)

**Shape E — delegated org admin** — `organization_members` via `is_org_admin()`

### Notable design decisions, all deliberate

- **`session_notes` has no guardian read policy.** A parent cannot read a
  coach's raw session notes. The parent-facing channel is `parent_updates`,
  which the guardian may read only at `status = 'sent'`. Coach drafts stay
  private until published. This is a good design and should not be "fixed".
- **`safety_reports` has no INSERT policy.** Reports can only be filed through
  the `submit_safety_report` SECURITY DEFINER RPC, so the write path is
  controlled. Correct.
- **`refund_requests` INSERT** requires the requester own the booking *and* the
  booking be `paid` or `partially_refunded`. Careful.
- **`plan_proposals` UPDATE** restricts the parent's write to `accepted` or
  `declined` only — a state machine in a `WITH CHECK`.

---

## 3. Triggers — 19

| table | trigger | function | timing |
|---|---|---|---|
| `bookings` | `trg_set_booking_price` | `set_booking_price` | BEFORE INSERT |
| `bookings` | `trg_enforce_booking_session_capacity` | `enforce_booking_session_capacity` | BEFORE INS/UPD |
| `bookings` | `trg_enforce_booking_member_org` | `enforce_booking_member_org` | BEFORE INS/UPD |
| `bookings` | `trg_enforce_booking_provider_update` | `enforce_booking_provider_update` | BEFORE UPDATE |
| `bookings` | `trg_snapshot_booking_cancellation_policy` | `snapshot_booking_cancellation_policy` | BEFORE INSERT |
| `bookings` | `trg_maintain_program_enrolled_count` | `maintain_program_enrolled_count` | AFTER INS/DEL/UPD |
| `bookings` | `trg_enqueue_lifecycle_on_booking` | `enqueue_lifecycle_on_booking` | AFTER UPDATE |
| `bookings` | `bookings_link_proposal` | `sporve_link_booking_to_proposal` | AFTER INS/UPD |
| `profiles` | `profiles_role_immutable` | `prevent_profile_role_change` | BEFORE UPDATE |
| `providers` | `trg_enforce_provider_trust` | `enforce_provider_trust` | BEFORE INS/UPD |
| `programs` | `trg_enforce_program_assignment` | `enforce_program_assignment` | BEFORE INS/UPD |
| `organization_members` | `trg_enforce_org_member` | `enforce_org_member` | BEFORE INS/UPD |
| `organization_members` | `trg_org_members_touch` | `tg_touch_updated_at` | BEFORE UPDATE |
| `messages` | `messages_rate_limit` | `enforce_message_rate_limit` | BEFORE INSERT |
| `plan_proposals` | `plan_proposals_parent_guard` | `sporve_plan_proposals_guard` | BEFORE UPDATE |
| `progress_digest_sources` | `progress_digest_source_guard` | `validate_progress_digest_source` | BEFORE INS/UPD |
| `athlete_goals` | `athlete_goals_touch` | `sporve_touch_updated_at` | BEFORE UPDATE |
| `development_plans` | `development_plans_touch` | `sporve_touch_updated_at` | BEFORE UPDATE |
| `lifecycle_message_prefs` | `trg_touch_lifecycle_prefs` | `touch_lifecycle_prefs` | BEFORE UPDATE |

---

## 4. Two guards verified, because RLS alone would not be enough

RLS grants row access. It does not restrict *which columns* an UPDATE may
touch. Two policies looked alarming for that reason. Both are correctly
backstopped by a trigger.

### `bookings_update_searcher` — `USING (searcher_id = auth.uid())`

On its own this would let a parent set their own booking to
`payment_status = 'paid'`. `enforce_booking_provider_update` prevents it by
freezing fifteen columns:

```
searcher_id, session_id, athlete_id, program_id, athlete_first_name,
athlete_age_band, selected_tier, original_price, final_price, currency,
cancellation_policy_snapshot, payment_status, refund_amount, refunded_at,
stripe_payment_intent_id
```

Any change to any of them raises. `status` is separately governed by an
explicit state machine — `cancelled` only from `pending`/`confirmed` by either
party; `declined` only from `pending` by the provider; `completed`/`no_show`
only from `confirmed` by the provider; everything else raises. Cancellation
metadata cannot be written without a real cancellation transition.

**Verdict: sound.**

### `organization_members_update_self` — `USING (member_user_id = auth.uid())`

On its own this would let a trainer mark themselves background-checked —
which would be the worst possible bug in this product. `enforce_org_member`
prevents it:

```sql
if tg_op = 'INSERT' then
  new.background_check_status := 'none';   -- born unverified, always
elsif new.background_check_status is distinct from old.background_check_status then
  raise exception 'background_check_status is server-controlled
                   — an org cannot verify its own trainers';
end if;
```

A trainer editing their own row may change profile fields only — not `role`,
`is_active`, `organization_id`, or `member_user_id`. The org must genuinely be
`provider_type = 'organization'`. Only the service role (where `auth.uid()` is
null, i.e. the background-check webhook) can set the status.

**Verdict: sound, and the comment in it shows the author understood exactly
what they were defending.**

---

## 5. The one systemic caveat

Every guard above short-circuits on `auth.uid() is null`:

```sql
if v_uid is null then return new; end if;
```

That is *required* — it is how the background-check webhook sets a verified
status and how migrations run. But it means **none of these triggers defend
against a compromised edge function.** Fourteen functions hold the service-role
key, and any of them can rewrite a role, a payment status, or a background-check
result without tripping a single guard.

The triggers stop the *client*. They do not stop the *server*. That distinction
should be written into any security review, because the trigger names
(`profiles_role_immutable`, `enforce_*`) promise more than they deliver.

---

## 6. What this inventory does not cover

- Column-level detail for the 36 tables — needs `supabase db dump`, which needs
  the owner's CLI (backlog 0.2).
- Constraints, indexes, and defaults — same.
- ~~Storage bucket policies~~ — **queried: `storage.buckets` is EMPTY.** There
  are zero buckets in production. The `provider-media` bucket with unconditional
  `anon` read (`20260801_000200:54-57`) is authored but **not applied**, so that
  exposure is not live. Media upload is not a working feature in prod. Do not
  apply that migration as written — fix the policy first.
- Row counts, including how many approved providers are exposed by the
  `providers` leak and how many orphaned auth users exist. **Both queries were
  blocked by the permission classifier**, not by any technical limit.
