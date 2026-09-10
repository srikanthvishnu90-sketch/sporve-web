-- Executes actual catalog/trial resolver AND actual capacity guards together.
-- Table shells remain isolated fixture shapes, not a production-policy replay.
\ir 2026-09-08-plan-entitlements.test.sql

begin;
create extension if not exists pgcrypto;
alter table public.organization_members
 add column id uuid primary key default gen_random_uuid(),
 add column role text not null default 'trainer';
create table public.team_athletes (
 id uuid primary key default gen_random_uuid(),provider_id uuid not null references public.providers(id),
 team_id uuid,athlete_id uuid,status text not null default 'active',first_name text
);
create table public.teams (
 id uuid primary key default gen_random_uuid(),provider_id uuid not null references public.providers(id),name text not null
);
commit;

\ir 2026-09-08-entitlement-guards.sql
\ir 2026-09-10-entitlement-http.setup.sql

begin;
-- The shared least-privilege setup revokes public RPC access; restore only the
-- actual authenticated entitlement-read RPC for these customer requests.
grant execute on function public.get_provider_entitlements(uuid) to authenticated;

-- New-provider trigger creates a genuine14-day Organization trial for all7.
insert into public.providers(id,owner_id)
 select ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
        ('10000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid
 from generate_series(1,7) n;
update public.provider_entitlement_assignments
 set plan_key=case provider_id::text
   when '00000000-0000-0000-0000-000000000002' then 'solo'
   when '00000000-0000-0000-0000-000000000003' then 'organization'
   else 'free' end,
   source='legacy',ends_at=null
 where provider_id in ('00000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
   '00000000-0000-0000-0000-000000000004');
insert into public.team_athletes(provider_id,first_name)
 select ('00000000-0000-0000-0000-'||lpad(org::text,12,'0'))::uuid,'integrated-'||n
 from (values(1),(5),(6),(7)) as organizations(org) cross join generate_series(1,15) n;
insert into public.team_athletes(provider_id,first_name)
 select '00000000-0000-0000-0000-000000000004','concurrent-'||n from generate_series(1,14) n;
insert into public.teams(provider_id,name) values('00000000-0000-0000-0000-000000000001','First group');
-- Expire org5 after seeding, without changing providers.plan or running a cron.
update public.provider_entitlement_assignments
 set starts_at=clock_timestamp()-interval '14 days',ends_at=clock_timestamp()
 where provider_id='00000000-0000-0000-0000-000000000005';
commit;
