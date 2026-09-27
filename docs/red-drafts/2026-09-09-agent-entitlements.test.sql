-- Disposable PostgreSQL fixture for 2026-09-09-agent-entitlements.sql.
-- createdb sporv_agent_entitlements_fixture
-- psql -X -v ON_ERROR_STOP=1 -d sporv_agent_entitlements_fixture -f this-file.sql
-- dropdb sporv_agent_entitlements_fixture
\set ON_ERROR_STOP on
do $$
begin
  if current_database() <> 'sporv_agent_entitlements_fixture'
     or to_regclass('public.providers') is not null then
    raise exception 'refusing fixture: require fresh database sporv_agent_entitlements_fixture';
  end if;
end;
$$;
create extension if not exists pgcrypto;
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('fixture.uid',true),'')::uuid
$$;
create table public.providers(
  id uuid primary key, owner_id uuid not null, onboarding_completed boolean not null default true,
  agent_mode text not null default 'draft'
);
create table public.plan_entitlements(
  plan text primary key, public_slug text not null, sort_order integer not null,
  purchasable boolean not null, jobs text[] not null, scan_mode text not null,
  draft_quota_month integer not null
);
create table public.provider_entitlement_assignments(
  provider_id uuid primary key references public.providers(id), plan_key text not null
);
create table public.obligations(
  id uuid primary key default gen_random_uuid(), provider_id uuid not null references public.providers(id),
  kind text not null, status text not null default 'draft', title text not null default 'fixture',
  detail text, source_kind text not null, source_ref text not null, created_at timestamptz not null default now()
);
create unique index fixture_live_obligation_ref on public.obligations(provider_id,source_ref)
  where source_kind='agent' and status<>'void';
create table public.agent_findings(
  id uuid primary key default gen_random_uuid(), provider_id uuid not null references public.providers(id),
  kind text not null, code text not null, severity text not null, title text not null, detail text,
  source_ref text not null, evidence jsonb, status text not null default 'open', updated_at timestamptz not null default now(),
  amount_cents integer, run_id uuid, member_id uuid, subject_type text, subject_id uuid
);
create unique index fixture_open_finding_ref on public.agent_findings(provider_id,source_ref) where status<>'dismissed';
create function public.resolve_provider_entitlements_internal(p uuid) returns jsonb language sql stable as $$
  select jsonb_build_object('effective_plan',a.plan_key) from public.provider_entitlement_assignments a where a.provider_id=p
$$;
create function public.agent_autodraft_on(p uuid) returns boolean language sql stable as $$
  select onboarding_completed and agent_mode='draft' from public.providers where id=p
$$;
create function public.agent_mode(p uuid) returns text language sql stable as $$
  select agent_mode from public.providers where id=p
$$;
create function public.agent_read_on(p uuid) returns boolean language sql stable as $$
  select exists(select 1 from public.providers where id=p and onboarding_completed)
    and public.agent_mode(p) in ('observe','draft')
$$;

-- Empty real-shape relations used by the 18 captured READ statements. Their
-- columns are deliberately sourced from agent-read-source.sql, not invented
-- conceptual names. Keeping them empty makes every permitted statement run
-- while avoiding production-like fixture data.
create table public.fee_schedules(id uuid primary key,provider_id uuid,status text,member_id uuid,season_id uuid,program_id uuid);
create table public.installments(id uuid primary key,fee_schedule_id uuid,due_date date,status text,amount_cents integer,member_id uuid,attempt_count integer);
create table public.team_athletes(id uuid primary key,provider_id uuid,status text,first_name text,last_name text,team_id uuid,dob date);
create table public.guardians(id uuid primary key,email text);
create table public.guardian_links(guardian_id uuid,member_id uuid);
create table public.waiver_documents(id uuid primary key,provider_id uuid,version integer,title text);
create table public.waiver_signatures(id uuid primary key,waiver_document_id uuid,member_id uuid,document_version integer);
create table public.payment_event_ledger(stripe_object_id text,outcome text,event_type text);
create table public.sessions(id uuid primary key,program_id uuid,assigned_member_id uuid,start_date date,title text,address text,start_time text);
create table public.programs(id uuid primary key,provider_id uuid,title text,enrolled_count integer,max_capacity integer,status text,offering_type text);
create table public.teams(id uuid primary key,provider_id uuid,name text,target_size integer);
create table public.seasons(id uuid primary key,end_date date);
create table public.program_waitlist(id uuid primary key,provider_id uuid,status text,athlete_first_name text);
create table public.organization_members(
  id uuid primary key,organization_id uuid,is_active boolean,
  background_check_status text,background_check_completed_at timestamptz
);
create table public.agent_proposals(
  provider_id uuid,kind text,title text,detail text,proposed jsonb,
  why_finding_id uuid,run_id uuid,status text not null default 'pending'
);
create unique index fixture_pending_proposal_ref on public.agent_proposals(provider_id,kind,(proposed->>'ref'))
  where status='pending';
create function public.generate_treasurer_summary(p uuid default null,p_force boolean default false,p_run uuid default null)
returns integer language sql security definer as $$ select 0 $$;
create function public.generate_agent_proposals(p uuid default null,p_force boolean default false)
returns integer language sql security definer as $$ select 0 $$;
create function public.fixture_denied_read_probe() returns uuid language plpgsql as $$
begin raise exception 'FAIL: an unentitled READ query executed'; end $$;
-- Free does not buy staff-expiry reads. If the per-job guard is ever moved
-- below the SELECT, this view makes the fixture fail immediately.
create view public.staff_certifications as
  select public.fixture_denied_read_probe() as id,
    '10000000-0000-4000-8000-000000000001'::uuid as organization_id,
    current_date as expires_at, 'verified'::text as status, 'fixture'::text as kind,
    null::text as reference, null::uuid as member_user_id;

-- Exact current generator signatures from agent_v2/company_brain. Bodies are
-- minimal only because this isolated fixture tests the new wrapper/receipt SQL;
-- the draft renames the existing production bodies rather than replacing them.
create function public.generate_installment_followups(p uuid default null,p_force boolean default false,p_run uuid default null)
returns integer language plpgsql security definer as $$ begin
  insert into public.obligations(provider_id,kind,status,title,source_kind,source_ref)
  values(p,'fee','draft','fixture installment','agent','installment:'||gen_random_uuid()::text);
  return 1;
end $$;
create function public.generate_waiver_followups(p uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer as $$ select 0 $$;
create function public.generate_practice_reminders(p uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer as $$ select 0 $$;
create function public.generate_reactivation_drafts(p uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer as $$ select 0 $$;
create function public.generate_eligibility_report(p uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer as $$ select 0 $$;
create function public.generate_missing_info_requests(p uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer as $$ select 0 $$;
create function public.generate_idle_capacity_offers(p uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer as $$ select 0 $$;

insert into public.plan_entitlements values
 ('free','free',0,false,array['installment_followups','waiver_followups','overdue_summary','waivers_unsigned','reconciliation_drift','refund_exposure','waiver_drift','collection_trend','treasurer_summary'],'nightly',20),
 ('solo','individual',1,true,array['installment_followups','waiver_followups','practice_reminders','reactivation','eligibility_report','missing_info_requests','idle_capacity_offers','overdue_summary','missing_email','credential_expiry','waivers_unsigned','lapsed_members','reconciliation_drift','refund_exposure','staffing_gap','booking_unconfirmed','schedule_conflict','roster_gap','missing_data','waiver_drift','idle_capacity','waitlist_match','camp_to_program','collection_trend','org_structure','treasurer_summary','proposals'],'triggered',-1),
 ('organization','enterprise',2,true,array['installment_followups','waiver_followups','practice_reminders','reactivation','eligibility_report','missing_info_requests','idle_capacity_offers','overdue_summary','missing_email','credential_expiry','waivers_unsigned','lapsed_members','reconciliation_drift','refund_exposure','staffing_gap','booking_unconfirmed','schedule_conflict','roster_gap','missing_data','waiver_drift','idle_capacity','waitlist_match','camp_to_program','collection_trend','org_structure','treasurer_summary','proposals'],'ondemand',-1);
insert into public.providers values
 ('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',true,'draft'),
 ('10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000002',true,'draft'),
 ('10000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000003',true,'off');
insert into public.provider_entitlement_assignments values
 ('10000000-0000-4000-8000-000000000001','free'),
 ('10000000-0000-4000-8000-000000000002','solo'),
 ('10000000-0000-4000-8000-000000000003','solo');

\ir 2026-09-09-agent-entitlements.sql

-- Named SQL/PostgREST callers depend on argument names as well as types and
-- defaults. These are the seven live pg_proc names captured on 2026-09-09.
do $$ declare n integer; begin
  select count(*) into n
  from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public'
    and p.proname in ('generate_installment_followups','generate_waiver_followups','generate_practice_reminders','generate_reactivation_drafts','generate_eligibility_report','generate_missing_info_requests','generate_idle_capacity_offers')
    and p.proargnames=array['p_provider','p_force','p_run']::text[]
    and pg_get_function_identity_arguments(p.oid)='p_provider uuid, p_force boolean, p_run uuid';
  if n<>7 then raise exception 'FAIL: wrapper argument names/default-compatible signatures diverged from live pg_proc'; end if;
end $$;

-- Free nightly money job runs; free triggered/manual run gets PT402 before any
-- generator; Off remains zero even on a triggered-capable plan.
select set_config('fixture.uid','20000000-0000-4000-8000-000000000001',false);
do $$ begin
  if public.generate_installment_followups('10000000-0000-4000-8000-000000000001',false,gen_random_uuid())<>1 then
    raise exception 'FAIL: free nightly money job was not allowed'; end if;
  begin
    perform public.run_agent_drafts('10000000-0000-4000-8000-000000000001');
    raise exception 'FAIL: free manual run bypassed nightly scan mode';
  exception when sqlstate 'PT402' then null;
  end;
  -- Six money/document READ jobs run against empty real-shape relations. The
  -- staff-certification view above throws if its unentitled query is reached.
  if public.generate_agent_findings('10000000-0000-4000-8000-000000000001',false)<>0 then
    raise exception 'FAIL: empty free READ fixture unexpectedly found rows'; end if;
end $$;
-- An Off organization is deliberately an honest no-op, not a subscription
-- wall. It owns the provider and has a triggered-capable plan, so this covers
-- the mode branch separately from a free plan's scan-mode PT402.
select set_config('fixture.uid','20000000-0000-4000-8000-000000000003',false);
do $$ begin
  if public.run_agent_read('10000000-0000-4000-8000-000000000003')<>0 then
    raise exception 'FAIL: Off manual READ was not a no-op'; end if;
  if public.generate_installment_followups('10000000-0000-4000-8000-000000000003',true,gen_random_uuid())<>0
     or public.generate_waiver_followups('10000000-0000-4000-8000-000000000003',true,gen_random_uuid())<>0
     or public.generate_practice_reminders('10000000-0000-4000-8000-000000000003',true,gen_random_uuid())<>0
     or public.generate_reactivation_drafts('10000000-0000-4000-8000-000000000003',true,gen_random_uuid())<>0
     or public.generate_eligibility_report('10000000-0000-4000-8000-000000000003',true,gen_random_uuid())<>0
     or public.generate_missing_info_requests('10000000-0000-4000-8000-000000000003',true,gen_random_uuid())<>0
     or public.generate_idle_capacity_offers('10000000-0000-4000-8000-000000000003',true,gen_random_uuid())<>0 then
    raise exception 'FAIL: Off direct draft entrypoint was not a no-op'; end if;
  if public.generate_treasurer_summary('10000000-0000-4000-8000-000000000003',true,null)<>0
     or public.generate_agent_proposals('10000000-0000-4000-8000-000000000003',true)<>0 then
    raise exception 'FAIL: Off direct cron entrypoint was not a no-op'; end if;
end $$;

-- Now make the formerly denied relation ordinary and prove an Individual plan
-- can execute the complete captured 18-job body (all tables remain empty).
drop view public.staff_certifications;
create table public.staff_certifications(id uuid primary key,organization_id uuid,expires_at date,status text,kind text,reference text,member_user_id uuid);

-- Direct cron entrypoints cannot use p_force to turn Free into triggered work.
-- Nightly money summaries remain usable on Free; proposals remain unavailable.
select set_config('fixture.uid','20000000-0000-4000-8000-000000000001',false);
do $$ begin
  if public.generate_treasurer_summary('10000000-0000-4000-8000-000000000001',false,null)<>0 then
    raise exception 'FAIL: empty free nightly treasurer fixture found rows'; end if;
  begin
    perform public.generate_treasurer_summary('10000000-0000-4000-8000-000000000001',true,null);
    raise exception 'FAIL: free p_force bypassed treasurer scan mode';
  exception when sqlstate 'PT402' then null;
  end;
  begin
    perform public.generate_agent_proposals('10000000-0000-4000-8000-000000000001',true);
    raise exception 'FAIL: free p_force bypassed proposals entitlement';
  exception when sqlstate 'PT402' then null;
  end;
end $$;

-- A later BEFORE trigger can cancel the row after the quota check. The AFTER
-- receipt must not run, so this no-op never spends quota. An unmapped source is
-- fail-closed with a visible finding rather than becoming an unmetered draft.
create function public.fixture_suppress_after_quota_check() returns trigger language plpgsql as $$
begin if new.source_ref='installment:suppressed' then return null; end if; return new; end $$;
create trigger zz_fixture_suppress_after_quota_check before insert on public.obligations
  for each row execute function public.fixture_suppress_after_quota_check();
do $$ declare before_receipts integer; begin
  select count(*) into before_receipts from public.agent_draft_quota_receipts
   where provider_id='10000000-0000-4000-8000-000000000001';
  insert into public.obligations(provider_id,kind,status,title,source_kind,source_ref)
    values('10000000-0000-4000-8000-000000000001','fee','draft','suppressed','agent','installment:suppressed');
  if (select count(*) from public.agent_draft_quota_receipts where provider_id='10000000-0000-4000-8000-000000000001')<>before_receipts
    or exists(select 1 from public.obligations where source_ref='installment:suppressed') then
    raise exception 'FAIL: suppressed insert consumed quota or persisted a draft'; end if;
  insert into public.obligations(provider_id,kind,status,title,source_kind,source_ref)
    values('10000000-0000-4000-8000-000000000001','message','draft','unknown','agent','unknown:source');
  if exists(select 1 from public.obligations where source_ref='unknown:source')
    or not exists(select 1 from public.agent_findings where code='unmapped_agent_draft') then
    raise exception 'FAIL: unmapped draft was not fail-closed with a finding'; end if;
end $$;
drop trigger zz_fixture_suppress_after_quota_check on public.obligations;

-- Fill the free quota through the real wrapper. The next nightly run skips
-- before calling its generator, writes a count-bearing receipt finding, and
-- neither deleting an obligation nor a replay frees the immutable receipt.
do $$ declare i integer; before_count integer; after_count integer; begin
  for i in 1..19 loop
    perform public.generate_installment_followups('10000000-0000-4000-8000-000000000001',false,gen_random_uuid());
  end loop;
  if (select count(*) from public.agent_draft_quota_receipts where provider_id='10000000-0000-4000-8000-000000000001')<>20 then
    raise exception 'FAIL: quota receipts did not reach 20'; end if;
  select count(*) into before_count from public.obligations where provider_id='10000000-0000-4000-8000-000000000001';
  if public.generate_installment_followups('10000000-0000-4000-8000-000000000001',false,gen_random_uuid())<>0 then
    raise exception 'FAIL: cap did not skip nightly generator'; end if;
  select count(*) into after_count from public.obligations where provider_id='10000000-0000-4000-8000-000000000001';
  if after_count<>before_count or not exists(select 1 from public.agent_findings
      where provider_id='10000000-0000-4000-8000-000000000001' and code='draft_quota_reached'
        and (evidence->>'blocked_observations')::int>=1) then
    raise exception 'FAIL: quota skip lacked honest finding or wrote overflow draft'; end if;
  delete from public.obligations where id in (
    select id from public.obligations where provider_id='10000000-0000-4000-8000-000000000001' limit 1
  );
  if public.generate_installment_followups('10000000-0000-4000-8000-000000000001',false,gen_random_uuid())<>0 then
    raise exception 'FAIL: deleting a draft refilled quota'; end if;
end $$;

-- Individual supports triggered execution and unlimited quota.
select set_config('fixture.uid','20000000-0000-4000-8000-000000000002',false);
do $$ declare read_job text; read_jobs text[]:=array['overdue_summary','missing_email','credential_expiry','waivers_unsigned','lapsed_members','reconciliation_drift','refund_exposure','staffing_gap','booking_unconfirmed','schedule_conflict','roster_gap','missing_data','waiver_drift','idle_capacity','waitlist_match','camp_to_program','collection_trend','org_structure']; begin
  if (public.run_agent_drafts('10000000-0000-4000-8000-000000000002')->>'dues')::int<>1 then
    raise exception 'FAIL: individual triggered run did not execute'; end if;
  if (select count(*) from public.agent_draft_quota_receipts where provider_id='10000000-0000-4000-8000-000000000002')<>1 then
    raise exception 'FAIL: unlimited plan did not retain usage receipt'; end if;
  foreach read_job in array read_jobs loop
    if not public.agent_read_job_allowed('10000000-0000-4000-8000-000000000002',read_job,true) then
      raise exception 'FAIL: individual lacks captured READ job %',read_job; end if;
  end loop;
  if public.run_agent_read('10000000-0000-4000-8000-000000000002')<>0 then
    raise exception 'FAIL: empty individual READ fixture unexpectedly found rows'; end if;
  if public.generate_treasurer_summary('10000000-0000-4000-8000-000000000002',true,null)<>0
     or public.generate_agent_proposals('10000000-0000-4000-8000-000000000002',true)<>0 then
    raise exception 'FAIL: empty individual direct entrypoint fixture found rows'; end if;
  -- A downgrade is read at call time. The same provider immediately loses the
  -- p_force path without deletion; restoring its assignment restores paid work.
  update public.provider_entitlement_assignments set plan_key='free'
    where provider_id='10000000-0000-4000-8000-000000000002';
  begin
    perform public.generate_treasurer_summary('10000000-0000-4000-8000-000000000002',true,null);
    raise exception 'FAIL: downgrade bypassed treasurer gate';
  exception when sqlstate 'PT402' then null;
  end;
  begin
    perform public.generate_agent_proposals('10000000-0000-4000-8000-000000000002',true);
    raise exception 'FAIL: downgrade bypassed proposals gate';
  exception when sqlstate 'PT402' then null;
  end;
  update public.provider_entitlement_assignments set plan_key='solo'
    where provider_id='10000000-0000-4000-8000-000000000002';
  -- Trigger authority is a scan-mode entitlement, not a sentinel finding
  -- code. Removing overdue_summary from the catalog must not turn this into a
  -- false 402 while another entitled READ job remains.
  update public.plan_entitlements set jobs=array['missing_email'] where plan='solo';
  if public.run_agent_read('10000000-0000-4000-8000-000000000002')<>0 then
    raise exception 'FAIL: triggered scan depended on overdue_summary'; end if;
  update public.plan_entitlements set jobs=read_jobs||array['treasurer_summary','proposals'] where plan='solo';
end $$;

do $$ begin
  begin update public.agent_draft_quota_receipts set job='x'; raise exception 'FAIL: receipt update allowed';
  exception when object_not_in_prerequisite_state then null; end;
  begin delete from public.agent_draft_quota_blocks; raise exception 'FAIL: quota block delete allowed';
  exception when object_not_in_prerequisite_state then null; end;
  raise notice 'PASS: catalog job/scan enforcement, free money/document READ only with denied-query probe, all 18 Individual READ jobs, free manual PT402, Off mode, hard quota skip, immutable receipts, individual trigger';
end $$;
