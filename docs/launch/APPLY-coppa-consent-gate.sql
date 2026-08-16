-- ============================================================================
-- APPLY: COPPA CONSENT GATE  →  production tseszaprvtvqrkfpditu
-- ============================================================================
-- [CRITICAL-PATH] Consent. Drafted by Claude, APPLIED BY THE OWNER BY HAND.
--
-- WHAT THIS FIXES
-- `athletes` already carries parent_consent / consent_at / consent_version in
-- production, and NOTHING ENFORCES THEM. The athletes table has zero triggers.
-- A minor's record can be created with consent absent, and a booking made
-- against that athlete, and the database accepts both silently.
--
-- The enforcement was written on 2026-07-28 in
-- supabase/migrations/20260728_000203_coppa_gate.sql and never applied —
-- production's migration ledger stops at 20260725033343.
--
-- Sections 2–4 below are that migration VERBATIM. Section 1 is a pre-flight
-- backfill this database specifically needs. Nothing here is invented.
--
-- PRE-FLIGHT MEASURED 2026-08-11 against live data:
--   athletes total ................................. 2
--   parent_consent = true .......................... 2   ✅
--   consent_at null ................................ 0   ✅
--   consent_version null or blank .................. 1   ⚠️  §1 fixes this
--   bookings naming an athlete ..................... 9
--   bookings on an unconsented athlete ............. 0   ✅
--   bookings with an orphaned athlete_id ........... 0   ✅
--
-- WHY §1 IS REQUIRED. The trigger fires BEFORE INSERT **OR UPDATE**. One
-- existing row has a blank consent_version, so once the gate is live any UPDATE
-- to that row — including one the app makes for an unrelated reason — would
-- raise. Backfill first, or you ship a row that cannot be edited.
--
-- SAFE TO RE-RUN. Every statement is idempotent: drop-if-exists before add,
-- create-or-replace, drop-trigger-if-exists.
--
-- HOW TO RUN
--   1. https://supabase.com/dashboard/project/tseszaprvtvqrkfpditu/sql/new
--   2. Paste this entire file.
--   3. Press RUN. It is one transaction — all of it lands or none of it does.
--   4. Run §6 afterwards and confirm every row says PASS.
-- ============================================================================

begin;

-- ── §1 · PRE-FLIGHT BACKFILL ────────────────────────────────────────────────
-- One athlete row has parent_consent = true but no consent_version. Consent was
-- recorded; which version of the consent text the parent accepted was not.
--
-- The value below is deliberately marked as a backfill so it is never mistaken
-- for a real recorded acceptance in an audit. These 2 rows are seed data, which
-- is the only reason writing a synthetic value here is acceptable.
--
-- ⚠️  IF A ROW HERE WERE A REAL CHILD, DO NOT RUN THIS SECTION. You cannot
--     invent which consent text a real parent agreed to. You would re-request
--     consent from that parent and record the true version.
update public.athletes
   set consent_version = 'backfill-2026-08-11-seed',
       consent_at      = coalesce(consent_at, now())
 where parent_consent is true
   and (consent_version is null or char_length(trim(consent_version)) = 0);

-- ── §2 · DEFENCE-IN-DEPTH CHECK CONSTRAINT ──────────────────────────────────
-- NOT VALID: enforced on every INSERT and on any UPDATE going forward, but does
-- not retro-validate existing rows. After §1 there is nothing left to spare,
-- but NOT VALID is kept so this file stays identical to the migration and safe
-- on any future database that does have legacy rows.
alter table public.athletes drop constraint if exists athletes_consent_required;
alter table public.athletes add constraint athletes_consent_required
  check (
    parent_consent = true
    and consent_at is not null
    and consent_version is not null
    and char_length(trim(consent_version)) > 0
  ) not valid;

-- ── §3 · ATHLETE CONSENT TRIGGER — the primary gate ─────────────────────────
-- Better error messages than a bare CHECK, and it stamps consent_at at the
-- moment consent is recorded.
--
-- NOTE, and this is deliberate: the service role is NOT exempted. Every other
-- guard in this database short-circuits on `if auth.uid() is null then return
-- new`, which lets the service role through. This one does not, because there
-- is no legitimate path that creates a consent-less minor — not the app, not an
-- admin backend, not a webhook.
create or replace function public.enforce_athlete_consent()
  returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce(new.parent_consent, false) is not true then
    raise exception 'parental consent (parent_consent = true) is required before an athlete record can exist (COPPA)';
  end if;
  if new.consent_version is null or char_length(trim(new.consent_version)) = 0 then
    raise exception 'consent_version (the consent text version the parent accepted) is required';
  end if;
  -- Stamp the consent instant if the caller recorded consent but not the time.
  if new.consent_at is null then
    new.consent_at := now();
  end if;
  return new;
end;
$$;
revoke execute on function public.enforce_athlete_consent() from public, anon, authenticated;

drop trigger if exists trg_enforce_athlete_consent on public.athletes;
create trigger trg_enforce_athlete_consent
  before insert or update on public.athletes
  for each row execute function public.enforce_athlete_consent();

-- ── §4 · BOOKING CANNOT REFERENCE A NON-CONSENTED ATHLETE ───────────────────
-- A booking may legitimately carry a NULL athlete_id (denormalised first-name
-- only). But when it DOES name an athlete_id, that athlete must have consent on
-- file — closing the path where a pre-consent legacy athlete is pulled into a
-- new booking.
--
-- Fails CLOSED: a missing athlete is rejected, not ignored.
-- SECURITY DEFINER here (unlike §3) because it must read `athletes` across the
-- parent-only RLS policy to check a row the booking's author may not own.
create or replace function public.enforce_booking_athlete_consent()
  returns trigger language plpgsql security definer set search_path = '' as $$
declare v_consent boolean;
begin
  if new.athlete_id is null then
    return new;                                            -- unnamed athlete: allowed
  end if;
  select a.parent_consent into v_consent
    from public.athletes a where a.id = new.athlete_id;
  if v_consent is null then
    raise exception 'booking references a non-existent athlete';
  end if;
  if v_consent is not true then
    raise exception 'cannot book: parental consent is not on file for this athlete (COPPA)';
  end if;
  return new;
end;
$$;
revoke execute on function public.enforce_booking_athlete_consent() from public, anon, authenticated;

drop trigger if exists trg_enforce_booking_athlete_consent on public.bookings;
create trigger trg_enforce_booking_athlete_consent
  before insert on public.bookings
  for each row execute function public.enforce_booking_athlete_consent();

-- ── §5 · RECORD IT IN THE LEDGER ────────────────────────────────────────────
-- Without this row the CLI still believes this migration is outstanding and
-- would re-run it on the first `supabase db push`. It is idempotent, so a re-run
-- is survivable — but the ledger should tell the truth, and this is the first
-- entry that will.
insert into supabase_migrations.schema_migrations (version, name)
values ('20260728000203', 'coppa_gate')
on conflict (version) do nothing;

commit;

-- ============================================================================
-- §6 · VERIFICATION — run this separately AFTER the commit above.
--      Every row must read PASS.
-- ============================================================================
select 'athlete consent fn'      as check,
       case when count(*)=1 then 'PASS' else 'FAIL' end as result
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='enforce_athlete_consent'
union all
select 'booking consent fn',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='enforce_booking_athlete_consent'
union all
select 'athlete trigger',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_trigger where tgname='trg_enforce_athlete_consent'
union all
select 'booking trigger',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_trigger where tgname='trg_enforce_booking_athlete_consent'
union all
select 'check constraint',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_constraint where conname='athletes_consent_required'
union all
select 'no athlete lacks consent_version',
       case when count(*)=0 then 'PASS' else 'FAIL' end
  from public.athletes
 where consent_version is null or char_length(trim(consent_version))=0
union all
select 'no booking on an unconsented athlete',
       case when count(*)=0 then 'PASS' else 'FAIL' end
  from public.bookings b join public.athletes a on a.id=b.athlete_id
 where a.parent_consent is not true
union all
select 'ledger row recorded',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from supabase_migrations.schema_migrations where version='20260728000203';

-- ============================================================================
-- §7 · LIVE-FIRE TEST — optional but recommended. Proves the gate BITES rather
--      than merely existing. Rolls itself back; writes nothing.
-- ============================================================================
-- begin;
--   -- Expect: ERROR  parental consent (parent_consent = true) is required...
--   insert into public.athletes (parent_id, first_name, date_of_birth, parent_consent)
--   values ((select id from public.profiles limit 1), 'GateTest', '2015-01-01', false);
-- rollback;

-- ============================================================================
-- §8 · ROLLBACK — only if the gate breaks a legitimate flow. Note that running
--      this re-opens the COPPA hole, so treat it as an incident, not a fix.
-- ============================================================================
-- begin;
--   drop trigger if exists trg_enforce_booking_athlete_consent on public.bookings;
--   drop trigger if exists trg_enforce_athlete_consent on public.athletes;
--   drop function if exists public.enforce_booking_athlete_consent();
--   drop function if exists public.enforce_athlete_consent();
--   alter table public.athletes drop constraint if exists athletes_consent_required;
--   delete from supabase_migrations.schema_migrations where version='20260728000203';
-- commit;
