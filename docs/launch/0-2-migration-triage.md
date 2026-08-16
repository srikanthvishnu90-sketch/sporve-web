# 0-2 · Migration triage — DDL manifest for 42 unlodged migrations

**Source directory:** `/Users/vishnusrikanth/SportsMan-main/supabase/migrations/`
**Scope:** the 42 files dated after production's last ledger entry `20260725033343`.
**Method:** static read of the SQL only. No database was contacted, no `supabase`
command was run, nothing was committed. **Nothing below states what is applied in
production** — that is the parent session's job, using the probe list in §2.

Legend: `[CP]` = CRITICAL-PATH (touches RLS, Stripe/money, auth/roles, booking
capacity, consent/COPPA, or background checks).

---

## 1 · The 42-row manifest

### 20260726_000000_booking_member_org_guard.sql `[CP]`
- **Purpose:** stops a searcher forging cross-org trainer attribution on a booking.
- **CREATE TABLE:** none
- **ADD COLUMN:** none
- **Functions:** `public.enforce_booking_member_org()` (create or replace)
- **Triggers:** `trg_enforce_booking_member_org` on `public.bookings` — `before insert or update of assigned_member_id, program_id, session_id`
- **Policies / Indexes:** none
- **WITNESS:** trigger `trg_enforce_booking_member_org` on `public.bookings`. **Caveat:** `20260729_000610` recreates the same function *and* the same trigger name, so presence alone does not separate the two. Discriminate on the trigger definition: this file's version watches **`assigned_member_id, program_id, session_id`**; `…000610`'s watches those **plus `service_id`**. Also `prosrc` here has no `services` branch.
- **Blast radius:** idempotent (`create or replace` + `drop trigger if exists`). Re-running is a no-op **except** that re-applying it *after* `…000610` silently downgrades the guard (see §B).

### 20260728_000000_universal_bgcheck_gate.sql `[CP]`
- **Purpose:** applies the per-human background-check gate to browse, search and booking-insert, not just the AI match path.
- **CREATE TABLE:** none
- **ADD COLUMN:** none
- **Functions:** `public.provider_safety_cleared(uuid)` (**new name**), `public.search_candidates(jsonb)` (replace), `public.enforce_booking_provider_verified()` (new), `public.enforce_provider_trust()` (replace — now also freezes `background_check_status` / `account_status`)
- **Triggers:** `trg_enforce_booking_provider_verified` on `public.bookings` (before insert)
- **Policies:** `providers_select_public`, `programs_select_public` (both dropped + recreated with the gate)
- **Indexes:** none
- **WITNESS:** function `public.provider_safety_cleared(uuid)` — the name exists in no other migration in the repo.
- **Blast radius:** idempotent. **Applying it flips discoverability**: every provider whose `background_check_status <> 'verified'` disappears from browse/search and becomes unbookable (file header, lines 26–34). The data step that marks legitimate demo providers verified is deliberately **not** in the file.

### 20260728_000001_north_star_metrics.sql
- **Purpose:** activation-funnel timestamps and two reporting views.
- **CREATE TABLE:** none
- **ADD COLUMN:** `providers.verified_at`, `providers.payout_enabled_at`, `providers.first_booking_at`
- **Functions:** `stamp_provider_activation()`, `stamp_provider_first_booking()`
- **Triggers:** `trg_stamp_provider_activation`, `trg_stamp_provider_first_booking`
- **Views:** `public.repeat_booking_stats`, `public.coach_activation_funnel`
- **WITNESS:** column `providers.verified_at`
- **Blast radius:** fully idempotent (`add column if not exists`, `create or replace`, and both views are preceded by `drop view if exists`, lines 109/142). Analytics only, no user-facing break.

### 20260728_000100_recurring_bookings.sql `[CP]`
- **Purpose:** recurring booking series, skips, and a credit ledger for missed sessions.
- **CREATE TABLE:** `public.recurring_bookings`, `public.recurring_booking_skips`, `public.booking_credits`
- **ADD COLUMN:** `bookings.recurring_booking_id`
- **Functions:** `enforce_recurring_booking_org()`, `enforce_booking_recurring_owner()`, `enforce_recurring_skip_owner()`, `enforce_booking_credits_owner()`, `consume_recurring_credit(...)`, `generate_recurring_sessions(uuid)`
- **Triggers:** `trg_enforce_recurring_booking_org`, `trg_enforce_booking_recurring_owner`, `trg_enforce_recurring_skip_owner`, `trg_enforce_booking_credits_owner`
- **Policies:** `recurring_bookings_{select_searcher,select_provider,insert_searcher,update_searcher,delete_searcher}`, `recurring_skips_{select_searcher,insert_searcher,delete_searcher}`, `booking_credits_{select_searcher,select_provider}`
- **Indexes:** `idx_recurring_bookings_{searcher,provider,program,member}`, `idx_recurring_skips_series`, `idx_booking_credits_searcher`, `idx_bookings_recurring`
- **WITNESS:** table `public.recurring_bookings`
- **Blast radius:** idempotent throughout. Credits are a money-adjacent ledger; applying out of order before `…000201`/`…000202` leaves the series unable to reference a `service_id`.

### 20260728_000101_platform_fees.sql `[CP]`
- **Purpose:** tunable platform take-rate rows read by the checkout edge function.
- **CREATE TABLE:** `public.platform_fees` (`fee_kind` PK, `rate_bps`, `description`, `updated_at`)
- **ADD COLUMN:** none
- **Functions:** `resolve_platform_fee_bps(...)`
- **Triggers / Indexes:** none. **Policies:** none — RLS enabled with **zero policies** = default deny, plus `revoke all … from anon, authenticated`.
- **WITNESS:** table `public.platform_fees`
- **Blast radius:** idempotent (`create table if not exists`, seed `on conflict do nothing`). **LOUD MISMATCH:** the seed rows are `first_booking = 1800 bps (18%)` and `recurring = 400 bps (4%)` (lines 20–36). The owner's recorded standing fact is a **flat 12% on every booking**. This file encodes the old 18/4 model. Applying it as-is installs the wrong take rate in the table the checkout function reads. Do not apply without the owner restating the intended rate.

### 20260728_000200_reviews.sql `[CP]`
- **Purpose:** double-blind two-sided reviews with a timed release window.
- **CREATE TABLE:** `public.review_windows`
- **ADD COLUMN:** `reviews.booking_id`, `reviews.author_role`, `reviews.reviewee_id`, `reviews.published_at`, `reviews.response_body`, `reviews.response_at`
- **Functions:** `is_booking_searcher(uuid)`, `is_booking_provider_owner(uuid)`, `enforce_review_authorship()`, `enforce_review_update()`, `publish_review_pair(uuid)`, `on_review_submitted()`, `release_due_reviews()`
- **Triggers:** `trg_enforce_review_authorship`, `trg_enforce_review_update`, `trg_on_review_submitted`
- **Policies:** `reviews_select_published`, `reviews_select_author`, `reviews_insert_author`, `reviews_update_author`, `reviews_update_provider_response`, `reviews_delete_author`, `review_windows_no_client`
- **Indexes:** `reviews_one_per_booking_side` (unique), `idx_reviews_booking`, `idx_reviews_published`, `idx_review_windows_due`
- **WITNESS:** table `public.review_windows`
- **Blast radius:** idempotent except the two `add constraint` statements, which are guarded by `drop constraint if exists` first. Safe to re-run.

### 20260728_000201_availability_truthfulness.sql `[CP]`
- **Purpose:** freshness / acceptance-rate / response-time signals, and the instant-book eligibility flag.
- **CREATE TABLE:** none
- **ADD COLUMN:** `providers.last_active_at`, `providers.instant_book_enabled`, `bookings.provider_responded_at`
- **Functions:** `stamp_booking_provider_response()`, `enforce_provider_availability_signals()`, `touch_provider_activity()`, `provider_is_fresh(uuid,int)`, `provider_acceptance_rate(uuid)`, `provider_median_response_seconds(uuid)`, `provider_instant_book_eligible(uuid)`, `admin_set_instant_book(uuid,boolean)`
- **Triggers:** `trg_stamp_booking_provider_response`, `trg_enforce_provider_availability_signals`
- **Views:** `public.stale_providers`. **Indexes:** `idx_providers_last_active`
- **WITNESS:** column `providers.instant_book_enabled`
- **Blast radius:** idempotent. `instant_book_enabled` becomes server-controlled by the new trigger — applying this after a client already writes the column would start rejecting those writes.

### 20260728_000202_resolution_center.sql `[CP]`
- **Purpose:** a dispute record between the two parties to a booking.
- **CREATE TABLE:** `public.disputes`
- **ADD COLUMN:** none
- **Functions:** `is_booking_party(uuid)`, `enforce_dispute_insert()`, `enforce_dispute_update()`
- **Triggers:** `trg_disputes_touch`, `trg_enforce_dispute_insert`, `trg_enforce_dispute_update`
- **Policies:** `disputes_select_party`, `disputes_insert_party`, `disputes_update_party`
- **Indexes:** `idx_disputes_booking`, `idx_disputes_opener`, `idx_disputes_queue`, `disputes_one_open_per_booking` (unique)
- **WITNESS:** table `public.disputes`
- **Blast radius:** fully idempotent; all three triggers are preceded by `drop trigger if exists` (lines 80, 132, 191).

### 20260728_000203_coppa_gate.sql `[CP]`
- **Purpose:** makes recorded parental consent an **enforced** database gate on athletes and on any booking naming an athlete.
- **CREATE TABLE:** none. **ADD COLUMN:** none — it only enforces columns that already exist on `athletes` (`parent_consent`, `consent_at`, `consent_version`).
- **Constraints:** `athletes_consent_required` (CHECK, `NOT VALID` — guards new writes, spares legacy rows)
- **Functions:** `enforce_athlete_consent()` (**new name**), `enforce_booking_athlete_consent()` (**new name**)
- **Triggers:** `trg_enforce_athlete_consent` on `public.athletes` (before insert or update), `trg_enforce_booking_athlete_consent` on `public.bookings` (before insert)
- **Policies / Indexes:** none
- **WITNESS:** trigger `trg_enforce_athlete_consent` on `public.athletes`. Secondary: constraint `athletes_consent_required` on `public.athletes`.
- **Blast radius:** fully idempotent (`drop constraint if exists`, `create or replace`, `drop trigger if exists`). **Service role is deliberately NOT exempted** (lines 32–34): after this applies, *no* path — including admin scripts and seeders — can create an athlete without `parent_consent = true` and a non-empty `consent_version`. Any existing seed/import job that omits those fields starts failing the moment this lands.

### 20260728_000300_waitlist.sql `[CP]`
- **Purpose:** a per-program waitlist a family can join.
- **CREATE TABLE:** `public.program_waitlist`
- **Functions:** `is_program_provider_owner(uuid)`, `enforce_waitlist_write()`
- **Triggers:** `trg_enforce_waitlist_write`
- **Policies:** `program_waitlist_{insert_searcher,select_searcher,update_searcher,delete_searcher,select_provider,update_provider}`
- **Indexes:** `idx_program_waitlist_{program,provider,searcher}`, `uq_program_waitlist_active` (unique)
- **WITNESS:** table `public.program_waitlist`
- **Blast radius:** idempotent. `…000800` later reshapes this table (drops `program_id NOT NULL`, adds `service_id`), so applying `…000300` *after* `…000800` is harmless (all `if not exists`) but re-running `…000800`'s constraint work is required for coherence.

### 20260728_000400_coach_invites.sql
- **Purpose:** a coach invites a family with a redeemable token; attribution for coach-brought demand.
- **CREATE TABLE:** `public.coach_invites`
- **Functions:** `enforce_coach_invite()`, `redeem_coach_invite(text)`, `is_coach_brought_family(uuid,uuid)`
- **Triggers:** `trg_enforce_coach_invite`
- **Policies:** `coach_invites_{select_provider,select_redeemer,insert_provider,update_provider,delete_provider}`
- **Indexes:** `idx_coach_invites_provider`, `idx_coach_invites_redeemer`, `idx_coach_invites_token` (unique)
- **WITNESS:** table `public.coach_invites`
- **Blast radius:** idempotent. `…000510` replaces all three functions; re-applying this file afterwards reverts the `invite_kind` handling.

### 20260728_000401_referrals.sql `[CP]`
- **Purpose:** referral codes and a reserved-then-settled credit ledger applied at checkout.
- **CREATE TABLE:** `public.referral_config`, `public.referrals`, `public.referral_credits`
- **Functions:** `enforce_referral()`, `redeem_referral(text)`, `reserve_referral_credit(uuid,uuid)`, `settle_referral_credit(uuid)`, `release_referral_credit(uuid)`
- **Triggers:** `trg_enforce_referral`
- **Policies:** `referrals_{select_referrer,select_referee,insert_referrer,update_referrer,delete_referrer}`, `referral_credits_select_beneficiary`
- **Indexes:** `idx_referrals_referrer`, `idx_referrals_referee`, `idx_referrals_code` (unique), `idx_referrals_pair_once` (unique), `idx_referral_credits_beneficiary`, `idx_referral_credits_status`
- **WITNESS:** table `public.referral_credits`
- **Blast radius:** idempotent. Money-adjacent: credits reduce what a family pays. Applying the reserve/settle functions without the tables would fail loudly, not silently.

### 20260728_000500_recurring_slots.sql
- **Purpose:** a coach's repeating weekly slot template plus one-off exceptions.
- **CREATE TABLE:** `public.recurring_slots`, `public.slot_exceptions`
- **ADD COLUMN:** `bookings.recurring_slot_id`
- **Functions:** `enforce_booking_recurring_slot_provider()`
- **Triggers:** `trg_recurring_slots_updated_at`, `trg_enforce_booking_recurring_slot_provider`
- **Policies:** `recurring_slots_{select_public,select_owner,insert_owner,update_owner,delete_owner}`, `slot_exceptions_{select_public,select_owner,insert_owner,update_owner,delete_owner}`
- **Indexes:** `idx_recurring_slots_provider`, `idx_recurring_slots_active`, `idx_slot_exceptions_slot`, `idx_bookings_recurring_slot`
- **WITNESS:** table `public.recurring_slots`
- **Blast radius:** idempotent.

### 20260728_000600_coach_policies.sql
- **Purpose:** free-text coach policy fields shown on a listing (cancellation, what to bring, FAQ).
- **CREATE TABLE:** none
- **ADD COLUMN:** `providers.cancellation_policy`, `providers.what_to_bring`, `providers.travel_radius`, `providers.session_notes`, `providers.faq` (jsonb, default `'[]'`)
- **Constraints:** `providers_faq_is_array`
- **Functions / Triggers / Policies / Indexes:** none
- **WITNESS:** column `providers.cancellation_policy`
- **Blast radius:** fully idempotent, additive, no behaviour change. Lowest-risk file in the set.

### 20260728_000700_ai_drafts.sql `[CP]`
- **Purpose:** AI-drafted replies as invisible-to-parent `messages` rows, plus coach feedback on drafts.
- **CREATE TABLE:** `public.draft_feedback`
- **ADD COLUMN:** `messages.status` (default `'sent'`), `messages.visible_to_parent` (default true), `messages.intent`, `messages.confidence`
- **Constraints:** `messages_status_check`, `messages_intent_check`, `messages_confidence_check`, `messages_draft_invisible_check` (an `ai_draft` **must** have `visible_to_parent = false`)
- **Policies:** `messages_select_participant` (replaced — this is what hides drafts from the parent), `messages_insert_sender`, `messages_update_coach_draft`, `draft_feedback_{select_own,insert_own,update_own,delete_own}`
- **Indexes:** `idx_messages_ai_draft`
- **WITNESS:** column `messages.status`. Secondary: table `public.draft_feedback`.
- **Blast radius:** idempotent. **Order-critical:** the column exists before the policy that filters on it. If the columns land but `messages_select_participant` is not replaced, AI drafts are visible to parents — a partial apply here is worse than none.

### 20260728_000701_draft_reply_trigger.sql
- **Purpose:** fires an HTTP call (via `pg_net`) to generate a draft when a parent sends a message.
- **CREATE TABLE:** none. **ADD COLUMN:** none
- **Extensions:** `pg_net` (`create extension if not exists`)
- **Functions:** `notify_draft_reply_on_parent_message()` (**new name**)
- **Triggers:** `trg_draft_reply_on_parent_message`
- **WITNESS:** function `public.notify_draft_reply_on_parent_message()`. Secondary and equally sharp: extension `pg_net` present in `pg_extension`.
- **Blast radius:** idempotent. Depends on `messages.status` from `…000700`. Applying it first would create a trigger that references a column that does not exist — the failure is at trigger *execution*, not creation, so the break shows up as broken messaging rather than a failed migration.

### 20260728_000702_resolve_draft_rpc.sql
- **Purpose:** one RPC for the coach to send / edit / discard an AI draft.
- **Only object:** function `public.resolve_draft(...)` (**name unique to this file**)
- **WITNESS:** function `public.resolve_draft` — the only object it creates, and no other migration defines that name.
- **Blast radius:** idempotent (`create or replace`). Depends on `…000700`'s `messages.status` values.

### 20260729_000100_services_availability_locations.sql `[CP]`
- **Purpose:** the service/location/exception model plus the `bookable_slots` computation.
- **CREATE TABLE:** `public.locations`, `public.availability_exceptions`
- **ADD COLUMN:** `providers.buffer_minutes`, `providers.vacation_until`, `services.service_type`, `services.sport`, `services.capacity`, `services.location_id`
- **Functions:** `bookable_slots(...)` (**new name**)
- **Triggers:** `trg_locations_updated_at`
- **Policies:** `services_select_public`, `availability_select_public`, `availability_select_owner`, `locations_{select_public,select_owner,insert_owner,update_owner,delete_owner}`, `availability_exceptions_{select_public,select_owner,insert_owner,update_owner,delete_owner}`
- **Indexes:** `idx_locations_provider`, `idx_services_location`, `idx_availability_exceptions_provider`
- **WITNESS:** table `public.locations`
- **Blast radius:** idempotent. **Note (loud):** this file does **not** create `services` or `availability` despite the filename — both pre-exist from `20260626_000000`; it only adds columns. It also rewrites `availability_select_public`, which a prior audit flagged as `USING (true)` — check the shipped predicate here before assuming the fix is in.

### 20260729_000200_group_seats.sql `[CP]`
- **Purpose:** bookings against a service+slot, and the seat-claim RPC for group sessions.
- **CREATE TABLE:** none
- **ADD COLUMN:** `bookings.service_id`, `bookings.slot_date`, `bookings.slot_time`
- **Functions:** `enforce_booking_provider_verified()` (replace — extends the bgcheck gate to service bookings), `enforce_booking_service_consistency()`, `claim_group_seat(...)` (**new name**), `group_slot_roster(...)`
- **Triggers:** `trg_enforce_booking_service_consistency`
- **Policies:** `bookings_select_provider`, `bookings_update_provider` (both replaced)
- **Indexes:** `idx_bookings_service_slot`
- **WITNESS:** column `bookings.service_id`. Secondary: function `public.claim_group_seat`.
- **Blast radius:** idempotent. **This file is the origin of the oversell hole** that `20260802_000103` closes: capacity is enforced only inside `claim_group_seat`, and the RLS insert policy lets a client bypass the RPC.

### 20260729_000201_recurring_on_service.sql
- **Purpose:** lets a recurring series point at a service rather than a program.
- **ADD COLUMN:** `recurring_bookings.service_id`
- **Functions:** `enforce_recurring_booking_org()` (replace), `generate_recurring_sessions(uuid)` (replace)
- **Triggers:** `trg_enforce_recurring_booking_org` (rebound)
- **Indexes:** `idx_recurring_bookings_service`
- **WITNESS:** column `recurring_bookings.service_id`
- **Blast radius:** idempotent. Hard dependency on `…000100` (the table) and `…000100/000200` (services). Both functions are `create or replace` over names first defined in `…000100`, so the function names are *not* usable witnesses.

### 20260729_000202_credit_packs.sql `[CP]`
- **Purpose:** prepaid credits against a service (packs), not just recurring-series credits.
- **ADD COLUMN:** `booking_credits.service_id`; `booking_credits.recurring_booking_id` altered to **drop not null**
- **Functions:** `enforce_booking_credits_owner()` (replace), `consume_credit(uuid,uuid)` (**new name**), `consume_recurring_credit(...)` (replace)
- **Indexes:** `idx_booking_credits_service`
- **WITNESS:** function `public.consume_credit(uuid, uuid)`. Secondary: column `booking_credits.service_id`.
- **Blast radius:** idempotent. Depends on `…000100` (booking_credits) and `…000100`/`…000200` (services). Money-adjacent: a credit is value the family already paid for.

### 20260729_000300_coach_invoices.sql `[CP]`
- **Purpose:** off-platform invoicing — a coach bills a contact directly, at a third fee kind.
- **CREATE TABLE:** `public.coach_contacts`, `public.coach_invoices`
- **Constraint change:** `platform_fees_fee_kind_check` widened to include `'offplatform'`
- **Functions:** `enforce_coach_invoice()`
- **Triggers:** `trg_enforce_coach_invoice`
- **Policies:** `coach_contacts_{select,insert,update,delete}_owner`, `coach_invoices_{select,insert,update}_owner`
- **Indexes:** `coach_contacts_provider_idx`, `coach_invoices_provider_idx`, `coach_invoices_contact_idx`
- **WITNESS:** table `public.coach_invoices`
- **Blast radius:** the `alter table … drop constraint platform_fees_fee_kind_check` is wrapped in a guarded `DO` block, so idempotent — **but it hard-depends on `platform_fees` existing** (`…000101`). Applied first, it errors on a missing table.

### 20260729_000500_commission_rates.sql `[CP]`
- **Purpose:** per-trainer commission rates, snapshotted onto each booking at write time.
- **CREATE TABLE:** `public.commission_rates`
- **ADD COLUMN:** `bookings.commission_member_id`, `bookings.commission_type`, `bookings.commission_value`, `bookings.commission_amount_cents`
- **Functions:** `enforce_commission_rate()`, `forbid_commission_rate_mutation()`, `resolve_member_commission(...)`, `snapshot_booking_commission()`
- **Triggers:** `trg_enforce_commission_rate`, `trg_forbid_commission_rate_mutation`, `trg_snapshot_booking_commission`
- **Policies:** `commission_rates_select_admin`, `commission_rates_select_self`, `commission_rates_insert_admin`
- **Indexes:** `idx_commission_rates_member_eff`, `idx_commission_rates_org`
- **WITNESS:** table `public.commission_rates`
- **Blast radius:** idempotent. Money path: the snapshot trigger derives what a trainer is owed **server-side**, which is the correct pattern; not applying it means commission is whatever the client says.

### 20260729_000510_trainer_affiliation.sql `[CP]`
- **Purpose:** invite an existing account to affiliate with an org; accept/decline flow.
- **ADD COLUMN:** `organization_members.affiliation_status` (default `'active'`), `coach_invites.invite_kind` (default `'family'`)
- **Functions:** `enforce_org_member()` (replace), `find_affiliatable_account(...)`, `invite_existing_account(...)`, `respond_to_affiliation(...)` (**new name**), `enforce_coach_invite()` (replace), `redeem_coach_invite(text)` (replace), `is_coach_brought_family(uuid,uuid)` (replace)
- **WITNESS:** column `organization_members.affiliation_status`. Secondary: function `public.respond_to_affiliation`.
- **Blast radius:** idempotent. Depends on `…000400` (coach_invites). Replaces three `…000400` functions — re-applying `…000400` afterwards regresses them.

### 20260729_000600_venue_resource_layer.sql `[CP]`
- **Purpose:** treats a location as a bookable resource and rejects double-booked venues.
- **ADD COLUMN:** `bookings.location_id`
- **Functions:** `booking_owning_provider(...)`, `enforce_booking_venue_conflict()`, `org_schedule_grid(...)` (**new name**)
- **Triggers:** `trg_enforce_booking_venue_conflict`
- **Indexes:** `idx_bookings_venue_slot`
- **WITNESS:** column `bookings.location_id`. Secondary: function `public.org_schedule_grid`.
- **Blast radius:** idempotent. Depends on `…000100` (locations) and `…000200` (booking slot columns). This is a capacity guard for physical space — a second venue booking on the same slot is a real-world collision, not just a data error.

### 20260729_000610_org_services.sql `[CP]`
- **Purpose:** which org trainers may be staffed on which service, and the any-available rule.
- **CREATE TABLE:** `public.service_assignable_members`
- **ADD COLUMN:** `services.assignable`
- **Functions:** `service_allows_any_available(uuid)` (**new name**), `enforce_service_assignable_member()`, `enforce_booking_member_org()` (**third redefinition**), `enforce_service_assignment()`
- **Triggers:** `trg_enforce_service_assignable_member`, `trg_enforce_booking_member_org` (rebound with `service_id` added), `trg_enforce_service_assignment`
- **Policies:** `sam_select_public`, `sam_select_admin`, `sam_insert_admin`, `sam_delete_admin`
- **Indexes:** `idx_sam_service`, `idx_sam_member`
- **WITNESS:** table `public.service_assignable_members`
- **Blast radius:** idempotent. Depends on `provider_safety_cleared` (`…000000`) inside `sam_select_public` — apply it without `…000000` and policy creation errors on an unknown function.

### 20260729_000620_shared_inbox.sql `[CP]`
- **Purpose:** routes a conversation to a service and an assigned org member; org-wide inbox view.
- **ADD COLUMN:** `conversations.service_id`, `conversations.assigned_member_id`
- **Functions:** `enforce_conversation_routing()`, `route_conversation(...)` (**new name**), `org_inbox(uuid)`
- **Triggers:** `trg_enforce_conversation_routing`
- **Policies:** `conversations_select_participant` (replaced), `messages_select_participant` (replaced **again** — after `…000700`)
- **Indexes:** `idx_conversations_assigned_member`, `idx_conversations_service`
- **WITNESS:** column `conversations.assigned_member_id`. Secondary: function `public.route_conversation`.
- **Blast radius:** idempotent, **but ordering matters for a safety-relevant policy**: it redefines `messages_select_participant`, which `…000700` had set up to hide AI drafts from parents. If this file's version omits the draft filter, applying it after `…000700` re-exposes drafts. Verify the live predicate, not the file order.

### 20260729_000700_camps.sql `[CP]`
- **Purpose:** multi-day camps as services, with early-bird and deposit pricing.
- **ADD COLUMN:** `services.starts_on`, `services.ends_on`, `services.daily_start_time`, `services.daily_end_time`, `services.age_band`, `services.early_bird_price_cents`, `services.early_bird_cutoff`, `services.deposit_cents`
- **Constraints:** `services_camp_daterange_check`, `services_camp_facets_only_on_camp`, `services_early_bird_paired`
- **Functions:** `camp_price_due(uuid, date)` (**new name**)
- **Indexes:** `idx_services_camp`
- **WITNESS:** column `services.starts_on`. Secondary: function `public.camp_price_due`.
- **Blast radius:** idempotent. `camp_price_due` is the server-side price derivation for camps — a money path; without it, price comes from the client.

### 20260729_000701_camp_roster.sql `[CP]`
- **Purpose:** camp roster with minors' emergency contact + medical notes, check-in, staff access gate.
- **CREATE TABLE:** `public.camp_roster`, `public.camp_checkins`
- **Constraints:** `camp_roster_emergency_is_object`
- **Functions:** `camp_staff_can_access(uuid)` (**new name here**), `register_camp_athlete(...)`, `camp_check_in(uuid,date)`, `camp_roster_view(uuid,date)`
- **Triggers:** `trg_camp_roster_updated_at`
- **Policies:** `camp_roster_select_staff`, `camp_checkins_select_staff`
- **Indexes:** `idx_camp_roster_service`, `idx_camp_roster_athlete`, `idx_camp_checkins_roster`
- **WITNESS:** table `public.camp_roster`
- **Blast radius:** idempotent. Depends on `…000700` (camp columns) and `…000610` (`service_assignable_members`). **This file ships the child-PII defect** that `20260802_000101` fixes: its `camp_staff_can_access` matches any org member staffed on the service without requiring `background_check_status = 'verified'`.

### 20260729_000800_waitlist_offers.sql `[CP]`
- **Purpose:** when a seat frees, offer it to the first matching waitlist entry with an expiry.
- **CREATE TABLE:** `public.waitlist_offers`
- **ADD COLUMN:** `program_waitlist.service_id`, `program_waitlist.slot_date`, `program_waitlist.slot_time`; `program_waitlist.program_id` **drops NOT NULL**
- **Constraints:** `program_waitlist_anchor_present` (program_id or service_id must be set)
- **Functions:** `is_service_provider_owner(uuid)` (**new name**), `enforce_waitlist_write()` (replace), `resolve_first_waitlist_match(...)`, `open_waitlist_seat(...)` (**new name**), `tg_waitlist_on_seat_free()`, `tg_waitlist_offer_on_message_sent()`, `accept_waitlist_offer(...)`, `decline_waitlist_offer(uuid)`, `roll_expired_waitlist_offers()`
- **Triggers:** `trg_waitlist_on_seat_free`, `trg_waitlist_offer_on_message_sent`
- **Policies:** `waitlist_offers_select` (reads only; all writes go through definer functions)
- **Indexes:** `idx_waitlist_offers_entry`, `idx_waitlist_offers_provider`, `idx_waitlist_offers_open`, `idx_waitlist_offers_draft`, `idx_program_waitlist_service`, `uq_program_waitlist_active_service` (unique)
- **WITNESS:** table `public.waitlist_offers`
- **Blast radius:** idempotent. Depends on `…000300` (program_waitlist), `…000200` (slot columns) and `…000700` (draft messages for `draft_message_id`). Capacity-adjacent: `accept_waitlist_offer` converts an offer into a seat.

### 20260729_000900_team_blocks.sql `[CP]`
- **Purpose:** a team books a block of sessions and splits payment across families.
- **CREATE TABLE:** `public.team_blocks`, `public.team_block_members`, `public.split_pay_links`
- **ADD COLUMN:** `bookings.team_block_id`
- **Functions:** `enforce_team_block_service()`, `enforce_split_pay_status()`, `team_block_even_shares(int,int)`, `create_split_pay_links(uuid)`, `redeem_split_share(...)` (**new name**), `team_block_split_status(uuid)`
- **Triggers:** `trg_team_blocks_updated_at`, `trg_enforce_team_block_service`, `trg_tbm_updated_at`, `trg_spl_updated_at`, `trg_enforce_split_pay_status`
- **Policies:** `team_blocks_{select,insert,update,delete}`, `tbm_select`, `tbm_write`, `spl_select`
- **Indexes:** `idx_team_blocks_service`, `idx_team_blocks_creator`, `idx_bookings_team_block`, `idx_tbm_block`, `idx_tbm_redeemed`, `idx_spl_block`
- **WITNESS:** table `public.split_pay_links`
- **Blast radius:** idempotent. Direct money path — split shares are what each family is charged.

### 20260801_000100_coach_agent_turns.sql
- **Purpose:** persistence for the coach AI agent's conversation turns and tool calls.
- **CREATE TABLE:** `public.coach_agent_turns`
- **Constraints:** `coach_agent_turns_tool_calls_is_array`
- **Functions:** `enforce_coach_agent_turn_write()` (**new name**)
- **Triggers:** `trg_enforce_coach_agent_turn_write`
- **Policies:** `coach_agent_turns_{select_own,insert_own,update_own}`
- **Indexes:** `idx_coach_agent_turns_coach`, `idx_coach_agent_turns_org`
- **WITNESS:** table `public.coach_agent_turns`
- **Blast radius:** idempotent. `20260801_000303` sets autovacuum params on this table and creates a BRIN index on it — apply `…000303` first and it errors on a missing table.

### 20260801_000200_provider_media_storage.sql `[CP]`
- **Purpose:** a real storage bucket for coach profile photo + gallery, with owner-prefix write RLS.
- **CREATE TABLE:** none. **Storage:** inserts bucket `provider-media` (public read) into `storage.buckets`.
- **ADD COLUMN:** `providers.profile_image`, `providers.gallery` (`text[]`, default `'{}'`)
- **Policies (on `storage.objects`):** `provider_media_public_read`, `provider_media_owner_insert`, `provider_media_owner_update`, `provider_media_owner_delete`
- **WITNESS:** column `providers.gallery`. Secondary and equally sharp: row `provider-media` in `storage.buckets`.
- **Blast radius:** idempotent (`on conflict (id) do update`, `drop policy if exists`). Public-read bucket: anything uploaded is world-readable by design, so this is a consent surface for any image containing a minor.

### 20260801_000300_scale_fk_indexes.sql
- **Purpose:** covering indexes on unindexed foreign keys. **Pure performance.**
- **Indexes (36):** `idx_bookings_athlete`, `idx_bookings_program`, `idx_bookings_cancelled_by`, `idx_messages_sender`, `idx_conversations_program`, `idx_program_waitlist_athlete`, `idx_recurring_bookings_athlete`, `idx_booking_credits_recurring`, `idx_waitlist_offers_program`, `idx_plan_proposals_provider`, `idx_plan_proposals_service`, `idx_progress_digest_sources_digest`, `idx_progress_digest_sources_note`, `idx_parent_updates_booking`, `idx_parent_updates_approved_by`, `idx_outbound_approved_by`, `idx_ai_audit_log_approved_by`, `idx_commission_rates_created_by`, `idx_coach_invites_inviter_owner`, `idx_disputes_decided_by`, `idx_disputes_proposed_session`, `idx_referral_credits_applied_booking`, `idx_referral_credits_referral`, `idx_refund_requests_booking`, `idx_refund_requests_requester`, `idx_privacy_requests_requester`, `idx_review_windows_booking`, `idx_reviews_author`, `idx_safety_reports_booking`, `idx_safety_reports_conversation`, `idx_safety_reports_provider`, `idx_safety_reports_reporter`, `idx_camp_roster_booking`, `idx_team_block_members_athlete`, `idx_team_blocks_one_payer`, `idx_split_pay_links_member`, `idx_split_pay_links_payer`
- **WITNESS:** index `idx_split_pay_links_payer` (the last-listed, so its presence also implies the file ran to completion).
- **Blast radius:** idempotent (`create index if not exists`). **Most order-dependent file in the set** — it indexes tables created by at least ten other files here (`waitlist_offers`, `camp_roster`, `team_block_members`, `split_pay_links`, `commission_rates`, `disputes`, `referral_credits`, `recurring_bookings`, `booking_credits`, `review_windows`). Any missing table aborts the whole file.

### 20260801_000301_scale_query_indexes.sql
- **Purpose:** composite indexes for the hot list queries. **Pure performance.**
- **Indexes (16):** `idx_messages_conversation_created`, `idx_notifications_user_created`, `idx_notifications_unread`, `idx_conversations_searcher_recent`, `idx_conversations_provider_recent`, `idx_services_provider_active_created`, `idx_availability_provider_day_time`, `idx_recurring_slots_provider_active_day`, `idx_locations_provider_active_name`, `idx_outbound_provider_drafted`, `idx_parent_updates_child_status_created`, `idx_athlete_goals_athlete_status_created`, `idx_plan_proposals_plan_status_rank`, `idx_progress_digests_athlete_created`, `idx_sessions_program_start`, `idx_program_waitlist_searcher_created`
- **WITNESS:** index `idx_program_waitlist_searcher_created`
- **Blast radius:** idempotent. Depends on `locations` (`…000100`) and `recurring_slots` (`…000500`).

### 20260801_000302_scale_rls_initplan.sql
- **Purpose:** rewrites every `public` RLS predicate's bare `auth.uid()` into `(select auth.uid())` so the planner hoists it into an InitPlan. **Pure performance, semantics-preserving.**
- **CREATE TABLE / ADD COLUMN / functions / triggers / policies / indexes:** **none** — it is a single anonymous `DO $$` block driving `ALTER POLICY` off `pg_policy`.
- **WITNESS:** *no created object exists.* Probe the catalog instead: count `pg_policies` rows in schema `public` whose `qual`/`with_check` still contain a **genuinely bare** `auth.uid()` after stripping any `( SELECT auth.uid() AS uid)` form. `0` ⇒ applied; `>0` ⇒ not applied (or not applied since the last policy was added). The file's own verification query is at lines 32–40 — use it verbatim. Note the check must be case-insensitive, because Postgres re-renders `SELECT` uppercase.
- **Blast radius:** genuinely idempotent by construction (strip-then-test, so a second run alters nothing). It reads the compiled predicate from the catalog rather than re-authoring it, so it cannot open a hole — but it will also silently miss any policy created *after* it runs, which means it should be re-run at the end of any migration batch.

### 20260801_000303_scale_append_only_tuning.sql
- **Purpose:** BRIN indexes and autovacuum tuning on append-only tables. **Pure performance.**
- **Indexes:** `brin_messages_created`, `brin_notifications_created`, `brin_coach_agent_turns_created`, `brin_outbound_messages_created`, `brin_ai_audit_log_created`, `brin_payment_event_ledger_processed`
- **ALTER TABLE … SET (storage params):** `messages`, `notifications`, `coach_agent_turns`, `outbound_messages`, `payment_event_ledger`, `ai_audit_log`, `bookings`
- **WITNESS:** index `brin_payment_event_ledger_processed`
- **Blast radius:** idempotent. Depends on `coach_agent_turns` (`20260801_000100`).

### 20260802_000101_fix_camp_roster_staff_bgcheck.sql `[CP]`
- **Purpose:** an org member must be **background-check verified and active** to read a camp's minors' emergency contacts and medical notes.
- **Only object:** `public.camp_staff_can_access(uuid)` (`create or replace`)
- **WITNESS:** *no new name.* Probe `pg_proc.prosrc` for `camp_staff_can_access` and test whether it contains **`background_check_status`** and **`is_active`**. Present ⇒ the fix is applied; absent (only `member_user_id = auth.uid()`) ⇒ `20260729_000701`'s vulnerable version is live.
- **Blast radius:** idempotent. Safe to apply twice. Applying it **without** `…000701` fails — the function would reference `service_assignable_members` and `camp_roster` that do not exist, and, more importantly, would be pointless.

### 20260802_000102_fix_booking_update_freeze_service_id.sql `[CP]`
- **Purpose:** freezes `service_id` / `slot_date` / `slot_time` on booking UPDATE, closing a background-check bypass.
- **Objects:** `public.enforce_booking_provider_update()` (`create or replace` — the name exists in `20260623_000000`, `20260630_000003` and `20260723_000006`), trigger `trg_enforce_booking_provider_update` (rebound)
- **WITNESS:** *no new name.* Probe `pg_proc.prosrc` for `enforce_booking_provider_update` and test for the literal **`new.service_id is distinct from old.service_id`**. Present ⇒ applied. Its absence is exactly the exploit: insert against a verified provider, then PATCH `service_id` to an unverified provider's service, since the bgcheck trigger is INSERT-only.
- **Blast radius:** idempotent. Applying it **before** `20260729_000200` fails at function creation — it references `new.service_id`, which does not exist until that file adds the column. This is the one ordering error in the corrective set that produces a hard error rather than a silent gap.

### 20260802_000103_fix_booking_slot_capacity_trigger.sql `[CP]`
- **Purpose:** enforces seat capacity **at the table** for every write path, not only inside `claim_group_seat`.
- **Objects:** `public.enforce_booking_slot_capacity()` (**new name**), trigger `trg_enforce_booking_slot_capacity` on `public.bookings` (before insert or update)
- **WITNESS:** function `public.enforce_booking_slot_capacity()` — unique in the repo. Secondary: the trigger of the same stem.
- **Blast radius:** idempotent. Depends on `20260729_000200` for `bookings.service_id/slot_date/slot_time` and on `20260729_000100` for `services.capacity`. It re-takes the *same* `pg_advisory_xact_lock(hashtext(service||'|'||date||'|'||time))` key as the RPC — reentrant inside one transaction, so the RPC and the trigger cannot disagree or double-reject.

### 20260802_000104_fix_refund_stranding_reconciliation.sql `[CP]`
- **Purpose:** a real Stripe refund with an unresolved payment-intent no longer gets recorded `ignored` while the booking still says `paid`; adds a stranded-event alarm.
- **Objects:** `public.apply_stripe_booking_event(text,text,uuid,text,bigint,text,text,timestamptz,text)` (`create or replace` — same 9-arg signature as `20260723_000006`), `public.flag_stranded_payment_events(integer)` (**new name**), `public.alert_stranded_payment_events(integer)` (**new name**); a guarded `DO` block that schedules pg_cron job `sporve-alert-stranded-payments` **only if** `pg_cron` is installed.
- **WITNESS:** function `public.flag_stranded_payment_events(integer)` — unique, and created only by this file.
- **Blast radius:** idempotent (`create or replace`, guarded cron unschedule/reschedule). Because the signature is unchanged, applying `…000105` afterwards *keeps* the refund fallback (it is copied verbatim there); applying `…000105` alone also gets the fallback. Applying `20260723_000006` again afterwards would **revert** the fallback.

### 20260802_000105_fix_p2_hardening.sql `[CP]`
- **Purpose:** three hardening items — `search_path = ''` on the Stripe applier, a service-role exemption on the profile-role guard, and forcing conversation creation through the RPC.
- **Objects:** `apply_stripe_booking_event(...)` (replace, `search_path` `'public'` → `''`), `prevent_profile_role_change()` (replace — adds `auth.uid() is null ⇒ return new`), trigger `profiles_role_immutable` (rebound), **drops policy `conversations_insert_participant`**, `ensure_provider_conversation(uuid,uuid)` (replace — now `security definer`)
- **WITNESS:** *no new name.* Best discriminator: **absence** of policy `conversations_insert_participant` on `public.conversations` in `pg_policies` **combined with** `pg_proc.prosecdef = true` for `ensure_provider_conversation`. Secondary: `pg_proc.proconfig` for `apply_stripe_booking_event` equals `{"search_path="}` (empty) rather than `{"search_path=public"}`.
- **Blast radius:** idempotent. **Two order traps.** (1) It contains the `…000104` refund fallback verbatim, so applying `…000105` *before* `…000104` and then applying `…000104` **downgrades `search_path` back to `public`** — the fallback survives, the hardening does not. (2) Dropping the insert policy without the `security definer` RPC landing leaves clients unable to start a conversation at all — messaging breaks. Both statements are in one file, so only a partial/failed apply produces that.

---

## 2 · Witness probe list

`filename → object type → object name`. Types map to a catalog query:
`table` → `to_regclass`, `column` → `information_schema.columns`,
`function` → `pg_proc`, `trigger` → `pg_trigger`, `policy` → `pg_policies`,
`index` → `pg_indexes`, `bucket` → `storage.buckets`, `extension` → `pg_extension`,
`prosrc` → substring test on `pg_proc.prosrc`, `proconfig` → `pg_proc.proconfig`.

```
20260726_000000_booking_member_org_guard.sql          | trigger  | trg_enforce_booking_member_org ON public.bookings   -- ambiguous with …000610; discriminate via pg_get_triggerdef NOT containing 'service_id'
20260728_000000_universal_bgcheck_gate.sql            | function | public.provider_safety_cleared(uuid)
20260728_000001_north_star_metrics.sql                | column   | public.providers.verified_at
20260728_000100_recurring_bookings.sql                | table    | public.recurring_bookings
20260728_000101_platform_fees.sql                     | table    | public.platform_fees
20260728_000200_reviews.sql                           | table    | public.review_windows
20260728_000201_availability_truthfulness.sql         | column   | public.providers.instant_book_enabled
20260728_000202_resolution_center.sql                 | table    | public.disputes
20260728_000203_coppa_gate.sql                        | trigger  | trg_enforce_athlete_consent ON public.athletes
20260728_000300_waitlist.sql                          | table    | public.program_waitlist
20260728_000400_coach_invites.sql                     | table    | public.coach_invites
20260728_000401_referrals.sql                         | table    | public.referral_credits
20260728_000500_recurring_slots.sql                   | table    | public.recurring_slots
20260728_000600_coach_policies.sql                    | column   | public.providers.cancellation_policy
20260728_000700_ai_drafts.sql                         | column   | public.messages.status
20260728_000701_draft_reply_trigger.sql               | function | public.notify_draft_reply_on_parent_message()
20260728_000702_resolve_draft_rpc.sql                 | function | public.resolve_draft
20260729_000100_services_availability_locations.sql   | table    | public.locations
20260729_000200_group_seats.sql                       | column   | public.bookings.service_id
20260729_000201_recurring_on_service.sql              | column   | public.recurring_bookings.service_id
20260729_000202_credit_packs.sql                      | function | public.consume_credit(uuid, uuid)
20260729_000300_coach_invoices.sql                    | table    | public.coach_invoices
20260729_000500_commission_rates.sql                  | table    | public.commission_rates
20260729_000510_trainer_affiliation.sql               | column   | public.organization_members.affiliation_status
20260729_000600_venue_resource_layer.sql              | column   | public.bookings.location_id
20260729_000610_org_services.sql                      | table    | public.service_assignable_members
20260729_000620_shared_inbox.sql                      | column   | public.conversations.assigned_member_id
20260729_000700_camps.sql                             | column   | public.services.starts_on
20260729_000701_camp_roster.sql                       | table    | public.camp_roster
20260729_000800_waitlist_offers.sql                   | table    | public.waitlist_offers
20260729_000900_team_blocks.sql                       | table    | public.split_pay_links
20260801_000100_coach_agent_turns.sql                 | table    | public.coach_agent_turns
20260801_000200_provider_media_storage.sql            | column   | public.providers.gallery                              -- secondary: bucket 'provider-media'
20260801_000300_scale_fk_indexes.sql                  | index    | idx_split_pay_links_payer
20260801_000301_scale_query_indexes.sql               | index    | idx_program_waitlist_searcher_created
20260801_000302_scale_rls_initplan.sql                | policy   | (no object) COUNT of public policies with a bare auth.uid() == 0
20260801_000303_scale_append_only_tuning.sql          | index    | brin_payment_event_ledger_processed
20260802_000101_fix_camp_roster_staff_bgcheck.sql     | prosrc   | camp_staff_can_access CONTAINS 'background_check_status'
20260802_000102_fix_booking_update_freeze_service_id.sql | prosrc | enforce_booking_provider_update CONTAINS 'new.service_id is distinct from old.service_id'
20260802_000103_fix_booking_slot_capacity_trigger.sql | function | public.enforce_booking_slot_capacity()
20260802_000104_fix_refund_stranding_reconciliation.sql | function | public.flag_stranded_payment_events(integer)
20260802_000105_fix_p2_hardening.sql                  | policy   | ABSENCE of conversations_insert_participant ON public.conversations  -- confirm with pg_proc.prosecdef=true for ensure_provider_conversation
```

Three probes are not simple existence checks and need the exact SQL:

```sql
-- 20260726 vs 20260729_000610 discriminator
select pg_get_triggerdef(t.oid) from pg_trigger t
 where t.tgname = 'trg_enforce_booking_member_org' and not t.tgisinternal;
-- contains 'service_id'  => …000610 version live
-- lacks   'service_id'   => only 20260726 ran

-- 20260801_000302 (no created object)
select count(*) from pg_policies
 where schemaname = 'public'
   and (coalesce(qual,'') || ' ' || coalesce(with_check,'')) ~* 'auth\.uid\(\)'
   and regexp_replace(coalesce(qual,'') || ' ' || coalesce(with_check,''),
         '\(\s*select\s+auth\.uid\(\)(\s+as\s+\w+)?\s*\)', '', 'gi') ~* 'auth\.uid\(\)';
-- 0 => applied

-- 20260802_000105 secondary
select proname, prosecdef, proconfig from pg_proc
 where proname in ('apply_stripe_booking_event','ensure_provider_conversation','prevent_profile_role_change');
-- apply_stripe_booking_event proconfig {search_path=}  => …000105 applied
-- apply_stripe_booking_event proconfig {search_path=public} => …000104 (or 20260723_000006) is the live version
```

---

## 3 · Answers

### A. Intra-set dependencies and apply order

Only these base objects come from **outside** the set and are assumed present:
`providers`, `programs`, `sessions`, `bookings`, `athletes`, `profiles`,
`conversations`, `messages`, `notifications` (baseline `20260623_000000`);
`services`, `availability` (`20260626_000000`); `reviews` (`20260704_000000`);
`organization_members`, `is_org_admin` (`20260708_000000`); `parent_updates`
(`20260629`); `outbound_messages` (`20260630_000000`); `plan_proposals`,
`athlete_goals` (`20260722_000000`); `progress_digests` (`20260722_000002`);
`payment_event_ledger`, `refund_requests`, `privacy_requests`, `safety_reports`,
`apply_stripe_booking_event` (`20260723_000006`); `ensure_provider_conversation`
(`20260723_000008`); `prevent_profile_role_change` (`20260723_000009`);
`ai_audit_log` (`20260628_000000`). **Nothing in the 42 references an object that
no migration anywhere in the repo creates.** No dangling reference found.

Dependency order (arrows = "must come after"):

```
Tier 0 (no intra-set deps)
  20260726_000000, 20260728_000000, 20260728_000001, 20260728_000201,
  20260728_000202, 20260728_000203, 20260728_000600, 20260728_000700,
  20260728_000101, 20260728_000100, 20260728_000300, 20260728_000400,
  20260728_000401, 20260728_000500, 20260729_000100

Tier 1
  20260728_000701  → 20260728_000700 (messages.status)
  20260728_000702  → 20260728_000700
  20260729_000200  → 20260729_000100 (services facets), 20260728_000000 (gate fn)
  20260729_000300  → 20260728_000101 (platform_fees table + fee_kind constraint)
  20260729_000510  → 20260728_000400 (coach_invites)
  20260729_000700  → 20260729_000100 (services.service_type='camp')

Tier 2
  20260729_000201  → 20260728_000100, 20260729_000100/000200
  20260729_000202  → 20260728_000100 (booking_credits), 20260729_000100
  20260729_000600  → 20260729_000100 (locations), 20260729_000200 (slot cols)
  20260729_000610  → 20260729_000100 (services), 20260728_000000 (provider_safety_cleared)
  20260729_000620  → 20260729_000100, 20260728_000700 (messages policy)
  20260729_000500  → (bookings only; safe anywhere after baseline)

Tier 3
  20260729_000701  → 20260729_000700 (camp cols), 20260729_000610 (service_assignable_members)
  20260729_000800  → 20260728_000300 (program_waitlist), 20260729_000200 (slots), 20260728_000700 (draft msgs)
  20260729_000900  → 20260729_000100/000200

Tier 4
  20260801_000100  (standalone)
  20260801_000200  (standalone)
  20260801_000300  → recurring_bookings, booking_credits, waitlist_offers,
                     commission_rates, disputes, referral_credits, review_windows,
                     camp_roster, team_block_members, split_pay_links, coach_invites
                     (i.e. after Tier 3 in full)
  20260801_000301  → 20260729_000100 (locations), 20260728_000500 (recurring_slots)
  20260801_000303  → 20260801_000100 (coach_agent_turns)
  20260801_000302  → run LAST in any batch (it rewrites whatever policies exist)

Tier 5 (correctives — see C)
  20260802_000101 → 20260729_000701
  20260802_000102 → 20260729_000200
  20260802_000103 → 20260729_000200, 20260729_000100
  20260802_000104 → (20260723_000006, outside the set)
  20260802_000105 → 20260802_000104, plus 20260723_000008/000009
```

**One cross-tier trap:** `20260729_000620` redefines `messages_select_participant`,
which `20260728_000700` created to hide AI drafts from parents. File order puts
`…000620` last, so the *live* predicate is whatever `…000620` says. Read that
predicate in production before assuming drafts are hidden — this is a
partial-apply hazard, not a missing-object one.

### B. `enforce_booking_member_org()` — three definitions

`~/Downloads/sporve-landing/supabase/migrations/20260726_000000_booking_member_org_guard.sql`
is **byte-identical** to the SportsMan copy (`diff` reports no difference).

`20260729_000610`'s version **is a strict superset** of `20260726`'s, on both axes:

| | 20260726 | 20260729_000610 |
|---|---|---|
| org resolution | `program_id` → `session_id` | `program_id` → `session_id` → **`service_id` → `services.provider_id`** |
| null `assigned_member_id` | allowed | allowed (identical) |
| unresolvable org | raise (fail closed) | raise (fail closed, same semantics) |
| membership test | `organization_members.id = assigned_member_id AND organization_id = v_org` | identical |
| trigger watch list | `assigned_member_id, program_id, session_id` | **+ `service_id`** |

Every branch of the older version is present unchanged; the newer one adds one
`elsif` and one watched column. No behaviour is removed.

**If a `db push` re-applied `20260726` afterwards, what is lost:** bookings whose
org is determined by `service_id` alone — i.e. every service-based booking with
`program_id` and `session_id` null, which is the entire post-`20260729_000200`
booking shape — fall into the `v_org is null` branch and **raise**, so a legitimate
org service booking that names a trainer is rejected outright. Worse in the other
direction: because the trigger is re-bound to `before insert or update of
assigned_member_id, program_id, session_id`, an UPDATE that changes **only
`service_id`** no longer fires the guard at all. A booking can therefore be
re-pointed to a different organization's service while keeping the original org's
`assigned_member_id` — exactly the forged cross-org attribution the file was
written to stop, reintroduced through the column it does not watch. Note this is
independent of `enforce_service_assignment` (also from `…000610`), which stays
bound to `service_id` — but that function only checks staffing on the service, not
that the assigned member belongs to the service's org.

### C. Which correctives depend on which of the earlier 37

| fix | depends on | if applied without it |
|---|---|---|
| `20260802_000101` camp staff bgcheck | **`20260729_000701`** (defines `camp_staff_can_access`, `camp_roster`, `camp_checkins`); transitively `20260729_000610` (`service_assignable_members`) and `20260729_000700` | Creating the function without `service_assignable_members` / `organization_members` reachable is a no-op at best; the tables it gates do not exist, so there is nothing to protect. Harmless but pointless. |
| `20260802_000102` freeze `service_id` | **`20260729_000200`** (adds `bookings.service_id/slot_date/slot_time`) | **Hard error.** PL/pgSQL resolves `new.service_id` at first execution; with no such column every booking UPDATE fails. This is the one corrective that breaks the app if ordered wrong. |
| `20260802_000103` slot capacity trigger | **`20260729_000200`** (slot columns, `claim_group_seat`) and **`20260729_000100`** (`services.capacity`) | Without the slot columns the trigger errors on every booking write. Without `…000100`'s `capacity`, `coalesce(sv.capacity, sv.max_athletes, 1)` silently falls back to `max_athletes` or 1 — a group service would be capped at one seat. |
| `20260802_000104` refund stranding | **`20260723_000006`** only — *outside* this set (defines `apply_stripe_booking_event` and `payment_event_ledger`) | Independent of all 37. Applying it where `20260723_000006` never ran creates a function against a `payment_event_ledger` that may not exist. |
| `20260802_000105` P2 hardening | **`20260802_000104`** (must be applied *before*, or the `search_path=public` version wins), plus `20260723_000008` (`ensure_provider_conversation`) and `20260723_000009` (`prevent_profile_role_change`), both outside this set | Applying `…000105` then `…000104` reverts `search_path` to `public` — the refund fallback survives, the hardening does not. Apply strictly `000104 → 000105`. |

Three of the five (`000101`, `000102`, `000103`) fix defects introduced **by files
in this set** (`…000701`, `…000200`, `…000200`). If those originals never reached
production, the corresponding fix is moot — and applying the original *without*
its fix ships a known child-safety or capacity hole. **Never apply `20260729_000701`
without `20260802_000101` in the same batch; never apply `20260729_000200` without
both `20260802_000102` and `20260802_000103`.**

### D. Ranked by launch risk if never applied (highest first)

1. **`20260728_000203_coppa_gate`** — a minor can be recorded and booked with no parental consent on file. Legal exposure (COPPA), not just a bug.
2. **`20260728_000000_universal_bgcheck_gate`** — an unverified adult is discoverable and bookable through browse, search and direct insert. The company's one differentiating promise is unenforced.
3. **`20260802_000101_fix_camp_roster_staff_bgcheck`** *(only if `…000701` is live)* — an unvetted org member reads minors' emergency contacts and medical notes.
4. **`20260802_000102_fix_booking_update_freeze_service_id`** *(only if `…000200` is live)* — documented bypass of #2: book verified, then PATCH to unverified.
5. **`20260802_000103_fix_booking_slot_capacity_trigger`** *(only if `…000200` is live)* — seat oversell on any direct PostgREST write; families arrive to a full session.
6. `20260802_000104_fix_refund_stranding_reconciliation` — a real refund leaves Stripe while the booking still reads `paid`. Money already moved; the customer sees nothing.
7. `20260802_000105_fix_p2_hardening` — mutable `search_path` on a security-definer money function, plus unguarded raw conversation inserts.
8. `20260729_000610_org_services` — an org can book a trainer who is not staffed on the service; the any-available rule for private sessions is unenforced.
9. `20260726_000000_booking_member_org_guard` — forgeable cross-org trainer attribution (superseded by #8, so its marginal value depends on #8's state).
10. `20260729_000600_venue_resource_layer` — two bookings in one physical venue at one time.
11. `20260728_000101_platform_fees` — **but see the 18/4 vs flat-12% mismatch above; applying it as written installs the wrong rate.** Risk is bidirectional.
12. `20260729_000500_commission_rates` — trainer commission is not server-derived.
13. `20260729_000900_team_blocks` — split-pay amounts unenforced.
14. `20260728_000401_referrals` — referral credit reserve/settle unenforced; double-spend of a credit.
15. `20260729_000300_coach_invoices` — off-platform invoicing has no fee kind, no guard.
16. `20260729_000202_credit_packs` — prepaid credits cannot be consumed correctly.
17. `20260728_000700_ai_drafts` — AI drafts visible to parents if the columns exist without the policy.
18. `20260729_000620_shared_inbox` — same policy surface, later definition.
19. `20260728_000200_reviews` — reviews can be authored by non-parties / published early.
20. `20260729_000800_waitlist_offers` — offers can be accepted past capacity.
21. `20260729_000701_camp_roster` — camps cannot run; **do not apply without #3**.
22. `20260729_000700_camps` — camp pricing derived client-side.
23. `20260729_000200_group_seats` — group booking does not exist; **do not apply without #4 and #5**.
24. `20260729_000100_services_availability_locations` — the service model itself; also carries the `availability_select_public` rewrite.
25. `20260728_000300_waitlist` · 26. `20260728_000500_recurring_slots` · 27. `20260728_000100_recurring_bookings` · 28. `20260729_000201_recurring_on_service` — feature completeness, no safety hole.
29. `20260728_000202_resolution_center` — no dispute path; support handles by hand.
30. `20260728_000400_coach_invites` · 31. `20260729_000510_trainer_affiliation` — growth mechanics.
32. `20260801_000200_provider_media_storage` — coach photos do not persist. Visible, not dangerous.
33. `20260728_000201_availability_truthfulness` — stale listings; a trust problem, not a safety one.
34. `20260728_000701_draft_reply_trigger` · 35. `20260728_000702_resolve_draft_rpc` — AI drafting inoperative.
36. `20260801_000100_coach_agent_turns` — agent has no memory.
37. `20260728_000600_coach_policies` — listing fields blank.
38. `20260728_000001_north_star_metrics` — reporting only.
39. `20260801_000300_scale_fk_indexes` · 40. `20260801_000301_scale_query_indexes` · 41. `20260801_000302_scale_rls_initplan` · 42. `20260801_000303_scale_append_only_tuning` — pure performance.

### E. Pure performance — safe to defer

Four files, no schema semantics, no security predicate authored by hand:

- `20260801_000300_scale_fk_indexes.sql` — 36 FK covering indexes.
- `20260801_000301_scale_query_indexes.sql` — 16 composite indexes.
- `20260801_000302_scale_rls_initplan.sql` — `auth.uid()` → `(select auth.uid())` in policy predicates; semantics-preserving by construction (it re-parses the compiled predicate from `pg_policy` rather than re-authoring it).
- `20260801_000303_scale_append_only_tuning.sql` — 6 BRIN indexes + autovacuum storage params.

Drop all four from the critical queue. Two operational caveats: `…000300` is the
most order-dependent file in the whole set (it indexes ten tables created by
others and aborts on the first missing one), and `…000302` should be re-run
**last**, after every other migration in a batch, because it only rewrites
policies that exist at the moment it runs.

---

## What I could not determine from the repo alone

- The intended platform fee. `20260728_000101` seeds 18% / 4%; the owner's
  standing record says flat 12%. The repo cannot settle which is current — only
  the owner can.
- Whether any of these ever ran in production. Nothing here asserts that; the
  probe list in §2 exists precisely because the file contents cannot answer it.

**Two idempotency questions I opened and then closed by checking** (both are
clean, so no caveat remains): `repeat_booking_stats` and `coach_activation_funnel`
are each preceded by `drop view if exists` (`20260728_000001:109,142`); every
`create trigger` in `…000202`, `…000100`, `…000701`, `…000900` and `…000500` is
preceded by a matching `drop trigger if exists`. All 42 files are re-runnable.
