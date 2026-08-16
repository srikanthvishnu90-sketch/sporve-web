-- Universal background-check gate — from 20260728_000000_universal_bgcheck_gate.sql
-- Pre-checked against production 2026-08-11:
--   * all 5 required columns exist on providers
--   * 23 approved providers, 23 active, 23 solo, 20 background-check verified
--   * SO: 20 stay visible, 3 become hidden (they are not verified — correct)
--   * prod's search_candidates is byte-identical to this base minus the gate line
--   * prod's enforce_provider_trust does NOT guard background_check_status today,
--     meaning a provider can currently self-verify. This replaces that.
begin;

create or replace function public.provider_safety_cleared(p_provider_id uuid)
  returns boolean language sql stable security definer set search_path = ''
as $g$
  select exists (
    select 1 from public.providers pv
    where pv.id = p_provider_id
      and pv.account_status = 'active'
      and (
        (pv.provider_type = 'solo' and pv.background_check_status = 'verified')
        or (pv.provider_type = 'organization'
           and exists (select 1 from public.organization_members m
                       where m.organization_id = pv.id
                         and m.background_check_status = 'verified'
                         and m.is_active = true))
      )
  );
$g$;
revoke execute on function public.provider_safety_cleared(uuid) from public;
grant  execute on function public.provider_safety_cleared(uuid) to anon, authenticated, service_role;

drop policy if exists providers_select_public on public.providers;
create policy providers_select_public on public.providers
  for select to anon, authenticated
  using (status = 'approved' and public.provider_safety_cleared(id));

drop policy if exists programs_select_public on public.programs;
create policy programs_select_public on public.programs
  for select to anon, authenticated
  using (status = 'published' and public.provider_safety_cleared(provider_id));

create or replace function public.search_candidates(constraints jsonb)
  returns table (program_id uuid, price numeric, dist double precision, avail boolean)
  language sql stable security definer set search_path = public, extensions as $s$
  with c as (
    select nullif(constraints->>'sport','') as sport,
      (constraints->>'athlete_age')::int as athlete_age,
      (constraints->>'lat')::double precision as lat,
      (constraints->>'lng')::double precision as lng,
      coalesce((constraints->>'within_days')::int, 30) as within_days
  )
  select pr.id, pr.price,
    case when c.lat is not null and c.lng is not null
              and pr.latitude is not null and pr.longitude is not null
      then 3959 * acos(least(1, greatest(-1,
            cos(radians(c.lat))*cos(radians(pr.latitude))*cos(radians(pr.longitude)-radians(c.lng))
            + sin(radians(c.lat))*sin(radians(pr.latitude)))))
      else null end as dist,
    exists (
      select 1 from public.sessions s
      where s.program_id = pr.id
        and s.start_date >= current_date
        and s.start_date <= current_date + c.within_days
        and (s.capacity = 0 or s.capacity > (
          select count(*) from public.bookings b
          where b.session_id = s.id and b.status in ('pending','confirmed')))
    ) as avail
  from public.programs pr cross join c
  where pr.status = 'published'
    and public.provider_safety_cleared(pr.provider_id)
    and (c.sport is null or lower(pr.sport_type) = lower(c.sport))
    and (c.athlete_age is null
         or ((pr.minimum_age is null or c.athlete_age >= pr.minimum_age)
             and (pr.maximum_age is null or c.athlete_age <= pr.maximum_age)));
$s$;
revoke execute on function public.search_candidates(jsonb) from public, anon, authenticated;

create or replace function public.enforce_booking_provider_verified()
  returns trigger language plpgsql security definer set search_path = '' as $b$
declare v_provider uuid;
begin
  if new.program_id is not null then
    select pr.provider_id into v_provider from public.programs pr where pr.id = new.program_id;
  elsif new.session_id is not null then
    select pr.provider_id into v_provider
      from public.sessions s join public.programs pr on pr.id = s.program_id
      where s.id = new.session_id;
  end if;
  if v_provider is null then
    raise exception 'booking has no resolvable program/provider to verify against';
  end if;
  if not public.provider_safety_cleared(v_provider) then
    raise exception 'cannot book: provider is not background-check verified and active';
  end if;
  return new;
end;
$b$;
revoke execute on function public.enforce_booking_provider_verified() from public, anon, authenticated;

drop trigger if exists trg_enforce_booking_provider_verified on public.bookings;
create trigger trg_enforce_booking_provider_verified
  before insert on public.bookings
  for each row execute function public.enforce_booking_provider_verified();

create or replace function public.enforce_provider_trust()
  returns trigger language plpgsql security definer set search_path = '' as $t$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    new.verification_status     := 'unverified';
    new.background_check_status := 'none';
    new.account_status          := 'active';
    new.stripe_charges_enabled  := false;
    new.stripe_account_id       := null;
  elsif tg_op = 'UPDATE' then
    if new.verification_status     is distinct from old.verification_status
     or new.background_check_status is distinct from old.background_check_status
     or new.account_status         is distinct from old.account_status
     or new.stripe_account_id       is distinct from old.stripe_account_id
     or new.stripe_charges_enabled  is distinct from old.stripe_charges_enabled then
      raise exception
        'verification_status / background_check_status / account_status / stripe fields are server-controlled and cannot be self-set';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.status in ('suspended','rejected') then
    new.status := old.status;
  else
    new.status := case when coalesce(new.onboarding_completed, false) then 'approved' else 'pending' end;
  end if;
  return new;
end;
$t$;
revoke execute on function public.enforce_provider_trust() from public, anon, authenticated;

insert into supabase_migrations.schema_migrations (version, name)
values ('20260728000000', 'universal_bgcheck_gate')
on conflict (version) do nothing;

commit;
