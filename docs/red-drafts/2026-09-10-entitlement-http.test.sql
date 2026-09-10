-- Isolated HTTP extension of the existing guard fixture, never production.
-- This tests the real guard functions through PostgREST with JWT roles.
-- Fixture-only RLS is deliberately owner-only; this is not a replay of every
-- production policy and must not be credited as the full tenancy audit.
\ir 2026-09-08-entitlement-guards.test.sql

begin;
do $$ begin
  if current_database() <> 'sporv_entitlement_guard_test' then
    raise exception 'HTTP fixture requires the disposable guard database';
  end if;
end $$;
create role fixture_authenticator login noinherit password 'fixture-only-http-password';
grant anon, authenticated to fixture_authenticator;

create or replace function auth.role() returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role'
$$;
create or replace function auth.uid() returns uuid language sql stable as $$
  select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid
$$;
grant usage on schema auth to anon,authenticated;
grant execute on function auth.role(),auth.uid() to anon,authenticated;
revoke all on all functions in schema public from public,anon,authenticated;
revoke all on all tables in schema public from public,anon,authenticated;
grant usage on schema public to fixture_authenticator,anon,authenticated;
grant select on public.plan_entitlements to anon,authenticated;
grant select on public.providers,public.team_athletes,public.teams,public.organization_members to authenticated;
grant insert,update,delete on public.team_athletes,public.teams,public.organization_members to authenticated;

alter table public.providers enable row level security;
alter table public.plan_entitlements enable row level security;
alter table public.provider_entitlement_assignments enable row level security;
alter table public.team_athletes enable row level security;
alter table public.teams enable row level security;
alter table public.organization_members enable row level security;
create policy fixture_provider_owner on public.providers for select to authenticated using(owner_id=auth.uid());
create policy fixture_catalog_read on public.plan_entitlements for select to anon,authenticated using(true);
create policy fixture_member_owner on public.team_athletes for all to authenticated
 using(exists(select 1 from public.providers p where p.id=provider_id and p.owner_id=auth.uid()))
 with check(exists(select 1 from public.providers p where p.id=provider_id and p.owner_id=auth.uid()));
create policy fixture_group_owner on public.teams for all to authenticated
 using(exists(select 1 from public.providers p where p.id=provider_id and p.owner_id=auth.uid()))
 with check(exists(select 1 from public.providers p where p.id=provider_id and p.owner_id=auth.uid()));
create policy fixture_admin_owner on public.organization_members for all to authenticated
 using(exists(select 1 from public.providers p where p.id=organization_id and p.owner_id=auth.uid()))
 with check(exists(select 1 from public.providers p where p.id=organization_id and p.owner_id=auth.uid()));

-- Keep the original legacy-alias unit cases intact, then exercise the current
-- constitution's catalog values in this separate real-HTTP fixture.
update public.plan_entitlements set public_slug='solo' where plan='solo';
update public.plan_entitlements set public_slug='organization',member_cap=150,admin_cap=5 where plan='organization';
insert into public.team_athletes(provider_id,first_name)
 values('00000000-0000-0000-0000-000000000001','api-fifteen');
insert into public.providers values
 ('00000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000004');
insert into public.provider_entitlement_assignments values
 ('00000000-0000-0000-0000-000000000004','free');
insert into public.team_athletes(provider_id,first_name)
 select '00000000-0000-0000-0000-000000000004','concurrent-'||n from generate_series(1,14) n;
commit;
