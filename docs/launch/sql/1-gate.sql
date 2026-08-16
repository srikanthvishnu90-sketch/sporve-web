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
