-- Isolated HTTP extension of the existing guard fixture, never production.
-- This tests the real guard functions through PostgREST with JWT roles.
-- Fixture-only RLS is deliberately owner-only; this is not a replay of every
-- production policy and must not be credited as the full tenancy audit.
\ir 2026-09-08-entitlement-guards.test.sql

\ir 2026-09-10-entitlement-http.setup.sql

begin;
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
