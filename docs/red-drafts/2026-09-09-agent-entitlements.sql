-- Prompt 1 [CRITICAL-PATH] review draft. NOT applied to production.
--
-- This draft protects the seven current draft generators whose exact function
-- signatures were captured in 20260901_001015, 20260904_001023 and
-- 20260902_001020, plus the 18-statement READ body captured from production
-- on 2026-09-09. Each READ job is gated before its own query.
--
-- Preconditions: reviewed plan-entitlements migration, current agent_v2/
-- company_brain functions, and existing obligations + agent_findings tables.
-- Inverse: restore the seven renamed generator definitions after comparison;
-- retain immutable quota receipts/blocks and do not delete customer drafts.

begin;

create table public.agent_draft_quota_receipts (
  provider_id uuid not null references public.providers(id) on delete restrict,
  usage_month date not null,
  source_ref text not null,
  job text not null,
  obligation_id uuid not null,
  created_at timestamptz not null default now(),
  primary key(provider_id,usage_month,source_ref),
  unique(obligation_id)
);
create table public.agent_draft_quota_blocks (
  provider_id uuid not null references public.providers(id) on delete restrict,
  usage_month date not null,
  source_ref text not null,
  job text not null,
  observed_at timestamptz not null default now(),
  primary key(provider_id,usage_month,source_ref)
);
alter table public.agent_draft_quota_receipts enable row level security;
alter table public.agent_draft_quota_blocks enable row level security;
revoke all on public.agent_draft_quota_receipts,public.agent_draft_quota_blocks
  from public,anon,authenticated,service_role;

create function public.prevent_agent_quota_history_mutation()
returns trigger language plpgsql set search_path='' as $$
begin
  raise exception 'agent draft quota history is append-only' using errcode='55000';
end;
$$;
revoke all on function public.prevent_agent_quota_history_mutation()
  from public,anon,authenticated,service_role;
create trigger agent_draft_quota_receipts_append_only before update or delete
  on public.agent_draft_quota_receipts for each row execute function public.prevent_agent_quota_history_mutation();
create trigger agent_draft_quota_blocks_append_only before update or delete
  on public.agent_draft_quota_blocks for each row execute function public.prevent_agent_quota_history_mutation();

create function public.agent_entitlement(p_provider uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
  perform 1 from public.providers where id=p_provider for share;
  if not found then raise no_data_found using message='Provider not found'; end if;
  perform 1 from public.provider_entitlement_assignments where provider_id=p_provider for share;
  select to_jsonb(e) into strict v from public.plan_entitlements e
   where e.plan=(public.resolve_provider_entitlements_internal(p_provider)->>'effective_plan')
   for share;
  return v;
end;
$$;
revoke all on function public.agent_entitlement(uuid) from public,anon,authenticated,service_role;

-- scan_mode is a capability ceiling: triggered includes the nightly path and
-- ondemand includes both earlier paths. p_force never changes this decision.
create function public.agent_job_allowed(p_provider uuid,p_job text,p_invocation text)
returns boolean language plpgsql security definer set search_path='' as $$
declare e jsonb; mode text;
begin
  if p_invocation not in ('nightly','triggered','ondemand') then
    raise exception 'Invalid agent invocation' using errcode='22023';
  end if;
  e:=public.agent_entitlement(p_provider);
  mode:=e->>'scan_mode';
  return p_job=any(array(select jsonb_array_elements_text(e->'jobs')))
    and case p_invocation
      when 'nightly' then mode in ('nightly','triggered','ondemand')
      when 'triggered' then mode in ('triggered','ondemand')
      when 'ondemand' then mode='ondemand'
    end;
end;
$$;
revoke all on function public.agent_job_allowed(uuid,text,text) from public,anon,authenticated,service_role;

create function public.record_agent_quota_block(p_provider uuid,p_job text,p_source_ref text)
returns void language plpgsql security definer set search_path='' as $$
declare m date:=date_trunc('month',now() at time zone 'UTC')::date; blocked integer; written integer;
begin
  -- Live 2026-09-09 pg_constraint capture shows agent_findings has CHECKs only
  -- for severity and status, not kind; 'agent' is therefore valid and keeps
  -- quota observations distinct from money/document/customer findings.
  insert into public.agent_draft_quota_blocks(provider_id,usage_month,source_ref,job)
    values(p_provider,m,p_source_ref,p_job) on conflict do nothing;
  select count(*) into blocked from public.agent_draft_quota_blocks
    where provider_id=p_provider and usage_month=m;
  insert into public.agent_findings(provider_id,kind,code,severity,title,detail,source_ref,evidence)
    values(p_provider,'agent','draft_quota_reached','warn','Draft limit reached',
      blocked || ' quota block observation(s) this month; no overflow draft was created.',
      'agent:draft-quota:'||p_provider::text||':'||m::text,
      jsonb_build_object('blocked_observations',blocked,'usage_month',m,'job',p_job))
  on conflict(provider_id,source_ref) where status<>'dismissed' do update set
    title=excluded.title,detail=excluded.detail,evidence=excluded.evidence,updated_at=now();
  get diagnostics written=row_count;
  if written<>1 then raise exception 'Draft quota finding was not written' using errcode='55000'; end if;
end;
$$;
revoke all on function public.record_agent_quota_block(uuid,text,text) from public,anon,authenticated,service_role;

create function public.agent_draft_quota_available(p_provider uuid,p_job text,p_source_ref text)
returns boolean language plpgsql security definer set search_path='' as $$
declare e jsonb; cap integer; used integer; m date:=date_trunc('month',now() at time zone 'UTC')::date;
begin
  e:=public.agent_entitlement(p_provider);
  -- Provider then assignment are locked in agent_entitlement before this
  -- per-provider mutex, matching the billing projection lock hierarchy.
  perform pg_advisory_xact_lock(hashtextextended(p_provider::text,41203));
  cap:=(e->>'draft_quota_month')::integer;
  select count(*) into used from public.agent_draft_quota_receipts
    where provider_id=p_provider and usage_month=m;
  if cap=-1 or used<cap then return true; end if;
  perform public.record_agent_quota_block(p_provider,p_job,p_source_ref);
  return false;
end;
$$;
revoke all on function public.agent_draft_quota_available(uuid,text,text) from public,anon,authenticated,service_role;

create function public.raise_agent_entitlement_402(p_provider uuid,p_reason text,p_limit integer,p_current integer)
returns void language plpgsql security definer set search_path='' as $$
declare e jsonb; current_slug text; current_order integer; upgrade text;
begin
  e:=public.agent_entitlement(p_provider);
  current_slug:=e->>'public_slug'; current_order:=(e->>'sort_order')::integer;
  select public_slug into upgrade from public.plan_entitlements x
   where x.purchasable and x.sort_order>current_order
     and (p_reason<>'draft_quota_month' or x.draft_quota_month=-1 or x.draft_quota_month>p_current)
     and (p_reason<>'agent_scan_mode' or x.scan_mode in ('triggered','ondemand'))
   order by x.sort_order limit 1 for share;
  raise exception using errcode='PT402',message='Entitlement limit reached',detail=jsonb_build_object(
    'reason',p_reason,'current_plan',current_slug,'upgrade_to',upgrade,
    'limit',p_limit,'current',p_current)::text;
end;
$$;
revoke all on function public.raise_agent_entitlement_402(uuid,text,integer,integer) from public,anon,authenticated,service_role;

-- BEFORE only reserves/checks. A receipt is written AFTER the real INSERT so a
-- later trigger returning NULL, a conflict no-op, or any failed insert can
-- never spend quota. The advisory xact lock held by the check remains held by
-- the after-trigger receipt writer until commit.
create function public.reserve_agent_draft_quota()
returns trigger language plpgsql security definer set search_path='' as $$
declare job text; written integer;
begin
  if new.source_kind<>'agent' or new.status<>'draft' then return new; end if;
  job:=case
    when new.source_ref like 'installment:%' then 'installment_followups'
    when new.source_ref like 'waiver:%' then 'waiver_followups'
    when new.source_ref like 'session:%:member:%' then 'practice_reminders'
    when new.source_ref like 'reactivation:%' then 'reactivation'
    when new.source_ref like 'eligibility:%' then 'eligibility_report'
    when new.source_ref like 'missinginfo:%' then 'missing_info_requests'
    when new.source_ref like 'capacityoffer:%' then 'idle_capacity_offers'
    else null
  end;
  if job is null then
    insert into public.agent_findings(provider_id,kind,code,severity,title,detail,source_ref,evidence)
      values(new.provider_id,'agent','unmapped_agent_draft','warn','Agent draft blocked',
        'A draft source was not mapped to a reviewed entitlement job; no draft was created.',
        'agent:unmapped-draft:'||new.provider_id::text||':'||md5(new.source_ref),
        jsonb_build_object('source_ref',new.source_ref))
    on conflict(provider_id,source_ref) where status<>'dismissed' do update set
      detail=excluded.detail,evidence=excluded.evidence,updated_at=now();
    get diagnostics written=row_count;
    if written<>1 then raise exception 'Unmapped draft finding was not written' using errcode='55000'; end if;
    return null;
  end if;
  if exists(select 1 from public.obligations o where o.provider_id=new.provider_id
      and o.source_kind='agent' and o.source_ref=new.source_ref and o.status<>'void') then
    return new;
  end if;
  if not public.agent_draft_quota_available(new.provider_id,job,new.source_ref) then return null; end if;
  return new;
end;
$$;
revoke all on function public.reserve_agent_draft_quota() from public,anon,authenticated,service_role;
drop trigger if exists agent_draft_quota_reservation on public.obligations;
create trigger agent_draft_quota_reservation before insert on public.obligations
  for each row execute function public.reserve_agent_draft_quota();

create function public.record_agent_draft_quota_receipt()
returns trigger language plpgsql security definer set search_path='' as $$
declare job text; m date:=date_trunc('month',now() at time zone 'UTC')::date; written integer;
begin
  if new.source_kind<>'agent' or new.status<>'draft' then return new; end if;
  job:=case
    when new.source_ref like 'installment:%' then 'installment_followups'
    when new.source_ref like 'waiver:%' then 'waiver_followups'
    when new.source_ref like 'session:%:member:%' then 'practice_reminders'
    when new.source_ref like 'reactivation:%' then 'reactivation'
    when new.source_ref like 'eligibility:%' then 'eligibility_report'
    when new.source_ref like 'missinginfo:%' then 'missing_info_requests'
    when new.source_ref like 'capacityoffer:%' then 'idle_capacity_offers'
    else null
  end;
  if job is null then raise exception 'Unmapped agent draft reached receipt writer' using errcode='55000'; end if;
  insert into public.agent_draft_quota_receipts(provider_id,usage_month,source_ref,job,obligation_id)
    values(new.provider_id,m,new.source_ref,job,new.id) on conflict do nothing;
  get diagnostics written=row_count;
  if written<>1 then raise exception 'Agent draft quota receipt was not written' using errcode='55000'; end if;
  return new;
end;
$$;
revoke all on function public.record_agent_draft_quota_receipt() from public,anon,authenticated,service_role;
drop trigger if exists agent_draft_quota_receipt on public.obligations;
create trigger agent_draft_quota_receipt after insert on public.obligations
  for each row execute function public.record_agent_draft_quota_receipt();

-- Current generator bodies are renamed, never copied from memory. The wrappers
-- make p_force select triggered capability; it cannot bypass entitlement,
-- onboarding, or Draft mode because the renamed bodies receive false.
alter function public.generate_installment_followups(uuid,boolean,uuid) rename to generate_installment_followups_unentitled;
alter function public.generate_waiver_followups(uuid,boolean,uuid) rename to generate_waiver_followups_unentitled;
alter function public.generate_practice_reminders(uuid,boolean,uuid) rename to generate_practice_reminders_unentitled;
alter function public.generate_reactivation_drafts(uuid,boolean,uuid) rename to generate_reactivation_drafts_unentitled;
alter function public.generate_eligibility_report(uuid,boolean,uuid) rename to generate_eligibility_report_unentitled;
alter function public.generate_missing_info_requests(uuid,boolean,uuid) rename to generate_missing_info_requests_unentitled;
alter function public.generate_idle_capacity_offers(uuid,boolean,uuid) rename to generate_idle_capacity_offers_unentitled;
revoke all on function public.generate_installment_followups_unentitled(uuid,boolean,uuid),
  public.generate_waiver_followups_unentitled(uuid,boolean,uuid),public.generate_practice_reminders_unentitled(uuid,boolean,uuid),
  public.generate_reactivation_drafts_unentitled(uuid,boolean,uuid),public.generate_eligibility_report_unentitled(uuid,boolean,uuid),
  public.generate_missing_info_requests_unentitled(uuid,boolean,uuid),public.generate_idle_capacity_offers_unentitled(uuid,boolean,uuid)
  from public,anon,authenticated,service_role;

create function public.run_entitled_draft_job(p_provider uuid,p_job text,p_force boolean,p_run uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare invocation text:=case when p_force then 'triggered' else 'nightly' end; n integer:=0; p record;
begin
  if p_provider is null then
    for p in select id from public.providers loop
      n:=n+public.run_entitled_draft_job(p.id,p_job,p_force,p_run);
    end loop;
    return n;
  end if;
  -- A disabled or incomplete organization is an honest no-op, even when a
  -- caller supplied p_force. Do not turn an Off switch into a paywall.
  if not public.agent_autodraft_on(p_provider) then return 0; end if;
  if not public.agent_job_allowed(p_provider,p_job,invocation) then
    if p_force then perform public.raise_agent_entitlement_402(p_provider,'agent_scan_mode',0,1); end if;
    return 0;
  end if;
  if not public.agent_draft_quota_available(p_provider,p_job,'agent:draft-quota-precheck:'||p_job) then
    if p_force then perform public.raise_agent_entitlement_402(p_provider,'draft_quota_month',
      (public.agent_entitlement(p_provider)->>'draft_quota_month')::integer,
      (select count(*) from public.agent_draft_quota_receipts where provider_id=p_provider
        and usage_month=date_trunc('month',now() at time zone 'UTC')::date)); end if;
    return 0;
  end if;
  case p_job
    when 'installment_followups' then n:=public.generate_installment_followups_unentitled(p_provider,false,p_run);
    when 'waiver_followups' then n:=public.generate_waiver_followups_unentitled(p_provider,false,p_run);
    when 'practice_reminders' then n:=public.generate_practice_reminders_unentitled(p_provider,false,p_run);
    when 'reactivation' then n:=public.generate_reactivation_drafts_unentitled(p_provider,false,p_run);
    when 'eligibility_report' then n:=public.generate_eligibility_report_unentitled(p_provider,false,p_run);
    when 'missing_info_requests' then n:=public.generate_missing_info_requests_unentitled(p_provider,false,p_run);
    when 'idle_capacity_offers' then n:=public.generate_idle_capacity_offers_unentitled(p_provider,false,p_run);
    else raise exception 'Unknown reviewed draft job' using errcode='22023';
  end case;
  return n;
end;
$$;
revoke all on function public.run_entitled_draft_job(uuid,text,boolean,uuid) from public,anon,authenticated,service_role;

create function public.generate_installment_followups(p_provider uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer set search_path='' as $$ select public.run_entitled_draft_job(p_provider,'installment_followups',p_force,p_run) $$;
create function public.generate_waiver_followups(p_provider uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer set search_path='' as $$ select public.run_entitled_draft_job(p_provider,'waiver_followups',p_force,p_run) $$;
create function public.generate_practice_reminders(p_provider uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer set search_path='' as $$ select public.run_entitled_draft_job(p_provider,'practice_reminders',p_force,p_run) $$;
create function public.generate_reactivation_drafts(p_provider uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer set search_path='' as $$ select public.run_entitled_draft_job(p_provider,'reactivation',p_force,p_run) $$;
create function public.generate_eligibility_report(p_provider uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer set search_path='' as $$ select public.run_entitled_draft_job(p_provider,'eligibility_report',p_force,p_run) $$;
create function public.generate_missing_info_requests(p_provider uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer set search_path='' as $$ select public.run_entitled_draft_job(p_provider,'missing_info_requests',p_force,p_run) $$;
create function public.generate_idle_capacity_offers(p_provider uuid default null,p_force boolean default false,p_run uuid default null) returns integer language sql security definer set search_path='' as $$ select public.run_entitled_draft_job(p_provider,'idle_capacity_offers',p_force,p_run) $$;
revoke all on function public.generate_installment_followups(uuid,boolean,uuid),
  public.generate_waiver_followups(uuid,boolean,uuid),public.generate_practice_reminders(uuid,boolean,uuid),
  public.generate_reactivation_drafts(uuid,boolean,uuid),public.generate_eligibility_report(uuid,boolean,uuid),
  public.generate_missing_info_requests(uuid,boolean,uuid),public.generate_idle_capacity_offers(uuid,boolean,uuid)
  from public,anon,authenticated,service_role;

-- Manual path: the owner may request a triggered run only when their plan has
-- that capability; Off/Observe still generate zero because underlying bodies
-- receive p_force=false and retain agent_autodraft_on/onboarding checks.
create or replace function public.run_agent_drafts(p_provider uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_run uuid:=gen_random_uuid(); v1 int; v2 int; v3 int; v4 int; v5 int; v6 int; v7 int;
begin
  if not exists(select 1 from public.providers where id=p_provider and owner_id=auth.uid()) then
    raise insufficient_privilege using message='only the org owner may run the agent';
  end if;
  v1:=public.generate_installment_followups(p_provider,true,v_run); v2:=public.generate_waiver_followups(p_provider,true,v_run);
  v3:=public.generate_practice_reminders(p_provider,true,v_run); v4:=public.generate_reactivation_drafts(p_provider,true,v_run);
  v5:=public.generate_eligibility_report(p_provider,true,v_run); v6:=public.generate_missing_info_requests(p_provider,true,v_run);
  v7:=public.generate_idle_capacity_offers(p_provider,true,v_run);
  return jsonb_build_object('dues',v1,'waivers',v2,'practice',v3,'reactivation',v4,'eligibility',v5,'missing_info',v6,'capacity_offer',v7,'total',v1+v2+v3+v4+v5+v6+v7,'run_id',v_run);
end;
$$;
revoke all on function public.run_agent_drafts(uuid) from public,anon;
grant execute on function public.run_agent_drafts(uuid) to authenticated;

-- Read-work gate. It is intentionally evaluated before each captured
-- generator statement, never as a post-insert visibility filter.
create or replace function public.agent_read_job_allowed(p_provider uuid,p_job text,p_force boolean default false)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  if p_provider is null then raise exception 'provider is required' using errcode='22023'; end if;
  if not public.agent_read_on(p_provider) then return false; end if;
  return public.agent_job_allowed(p_provider,p_job,case when p_force then 'triggered' else 'nightly' end);
end;
$$;
revoke all on function public.agent_read_job_allowed(uuid,text,boolean) from public,anon,authenticated,service_role;
-- Captured from production on 2026-09-09. Each of its 18 actual finding
-- statements is gated above its SELECT. p_force now selects the triggered
-- entitlement tier; it no longer bypasses agent mode or plan capability.
CREATE OR REPLACE FUNCTION public.generate_agent_findings(p_provider uuid DEFAULT NULL::uuid, p_force boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer := 0; v_run uuid := gen_random_uuid(); v_provider record;
  -- This declaration is the complete, captured READ surface. Keep it aligned
  -- with the 18 guarded statements below; it is intentionally not inferred
  -- from a plan, so a catalog typo cannot silently create unmetered work.
  v_source_jobs text[]:=array['overdue_summary','missing_email','credential_expiry','waivers_unsigned','lapsed_members','reconciliation_drift','refund_exposure','staffing_gap','booking_unconfirmed','schedule_conflict','roster_gap','missing_data','waiver_drift','idle_capacity','waitlist_match','camp_to_program','collection_trend','org_structure'];
begin
  -- Null means cron dispatch: enumerate providers first, then recurse into
  -- the single-provider path. No cross-organization generator query runs
  -- before that provider's mode and entitlement are known.
  if p_provider is null then
    for v_provider in select id from public.providers order by id loop
      n := n + public.generate_agent_findings(v_provider,p_force);
    end loop;
    return n;
  end if;
  if not public.agent_read_on(p_provider) then return 0; end if;
  -- (existing 5 kinds preserved) --------------------------------------------
  if public.agent_read_job_allowed(p_provider,'overdue_summary',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, amount_cents, run_id, evidence, subject_type)
  select p.id, 'money', 'overdue_summary',
    case when sum(i.amount_cents) >= 50000 then 'urgent' else 'warn' end,
    'Outstanding dues: ' || to_char(sum(i.amount_cents)/100.0,'FM$999,999,990.00') || ' across ' || count(distinct i.member_id) || ' member(s)',
    count(*) || ' installment(s) past due. Overdue derived from due date and status.',
    'finding:overdue:' || p.id || ':' || current_date, sum(i.amount_cents), v_run,
    jsonb_build_object('installments', count(*), 'members', count(distinct i.member_id)), 'provider'
  from public.providers p
  join public.fee_schedules fs on fs.provider_id = p.id and fs.status='active'
  join public.installments i on i.fee_schedule_id = fs.id and i.due_date < current_date and i.status not in ('paid','waived')
  where (p_provider is null or p.id=p_provider) and public.agent_read_on(p.id)
  group by p.id
  on conflict (provider_id, source_ref) where status <> 'dismissed'
  do update set title=excluded.title, detail=excluded.detail, amount_cents=excluded.amount_cents, severity=excluded.severity, evidence=excluded.evidence, run_id=excluded.run_id, updated_at=now();
  end if;
  get diagnostics n = row_count;
  if public.agent_read_job_allowed(p_provider,'missing_email',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, member_id, subject_type, subject_id, run_id)
  select m.provider_id, 'people', 'missing_email', 'info',
    m.first_name || ' ' || coalesce(m.last_name,'') || ' has no guardian email',
    'Dues reminders and waivers can''t reach this family until a guardian email is on file.',
    'finding:missing_email:' || m.id, m.id, 'member', m.id, v_run
  from public.team_athletes m
  where m.status='active' and m.first_name is not null
    and (p_provider is null or m.provider_id=p_provider) and public.agent_read_on(m.provider_id)
    and not exists (select 1 from public.guardian_links gl join public.guardians g on g.id=gl.guardian_id where gl.member_id=m.id and g.email is not null and g.email<>'')
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  if public.agent_read_job_allowed(p_provider,'credential_expiry',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, subject_type, subject_id, run_id)
  select sc.organization_id, 'people', 'credential_expiry',
    case when sc.expires_at <= current_date+7 then 'urgent' when sc.expires_at <= current_date+30 then 'attention' else 'info' end,
    sc.kind || ' expires ' || to_char(sc.expires_at,'Mon DD') || ' (' || (sc.expires_at-current_date) || ' days)',
    'Reference ' || coalesce(sc.reference,'—') || '. A lapsed check blocks assignment at the next event.',
    'finding:cred:' || sc.id || ':' || sc.expires_at, 'staff', sc.member_user_id, v_run
  from public.staff_certifications sc
  where sc.expires_at is not null and sc.expires_at <= current_date+60 and sc.status in ('verified','attested')
    and (p_provider is null or sc.organization_id=p_provider) and public.agent_read_on(sc.organization_id)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, severity=excluded.severity, run_id=excluded.run_id, updated_at=now();
  end if;
  if public.agent_read_job_allowed(p_provider,'waivers_unsigned',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, run_id)
  select wd.provider_id, 'documents', 'waivers_unsigned', 'warn',
    count(*) || ' member(s) have not signed a required waiver',
    'Current-version signatures are missing; these members can''t participate until signed.',
    'finding:waivers:' || wd.provider_id || ':' || current_date, v_run
  from public.waiver_documents wd
  join public.team_athletes m on m.provider_id=wd.provider_id and m.status='active'
  where wd.version = (select max(w2.version) from public.waiver_documents w2 where w2.provider_id=wd.provider_id and w2.title=wd.title)
    and not exists (select 1 from public.waiver_signatures ws where ws.waiver_document_id=wd.id and ws.member_id=m.id)
    and (p_provider is null or wd.provider_id=p_provider) and public.agent_read_on(wd.provider_id)
  group by wd.provider_id
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  if public.agent_read_job_allowed(p_provider,'lapsed_members',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, run_id)
  select p.id, 'clients', 'lapsed_members', 'info',
    count(*) || ' member(s) from last season haven''t re-enrolled',
    'First-party win-back candidates. The reactivation draft targets these in Draft mode.',
    'finding:lapsed:' || p.id || ':' || current_date, v_run
  from public.providers p
  join public.team_athletes m on m.provider_id=p.id and m.status='active' and m.first_name is not null
  where (p_provider is null or p.id=p_provider) and public.agent_read_on(p.id)
    and exists (select 1 from public.fee_schedules f join public.seasons s on s.id=f.season_id where f.member_id=m.id and s.end_date<current_date)
    and not exists (select 1 from public.fee_schedules f join public.seasons s on s.id=f.season_id where f.member_id=m.id and s.end_date>=current_date and f.status in ('active','complete'))
  group by p.id
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (1) reconciliation_drift: ledger rows with no stripe object id ------------
  if public.agent_read_job_allowed(p_provider,'reconciliation_drift',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, run_id, evidence)
  select fs.provider_id, 'money', 'reconciliation_drift', 'attention',
    count(*) || ' ledger row(s) with no Stripe object id',
    'Applied payment events missing a stripe_object_id — reconcile before close.',
    'finding:recon:' || fs.provider_id || ':' || current_date, v_run,
    jsonb_build_object('rows', count(*))
  from public.payment_event_ledger l
  join public.installments i on i.id::text = l.stripe_object_id or l.event_type like '%installment%'
  join public.fee_schedules fs on fs.id = i.fee_schedule_id
  where l.stripe_object_id is null and l.outcome='applied'
    and (p_provider is null or fs.provider_id=p_provider) and public.agent_read_on(fs.provider_id)
  group by fs.provider_id
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (2) refund_exposure: members with 2+ failed attempts AND an overdue -------
  if public.agent_read_job_allowed(p_provider,'refund_exposure',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, member_id, subject_type, subject_id, amount_cents, run_id)
  select fs.provider_id, 'money', 'refund_exposure', 'attention',
    m.first_name || ' ' || coalesce(m.last_name,'') || ' — repeated payment failures with a balance due',
    'This member has 2+ failed attempts and an overdue installment; likely to withdraw.',
    'finding:refundexp:' || m.id, m.id, 'member', m.id,
    (select sum(i2.amount_cents) from public.installments i2 where i2.member_id=m.id and i2.status not in ('paid','waived') and i2.due_date<current_date),
    v_run
  from public.team_athletes m
  join public.fee_schedules fs on fs.member_id=m.id and fs.status='active'
  where m.status='active'
    and (p_provider is null or fs.provider_id=p_provider) and public.agent_read_on(fs.provider_id)
    and exists (select 1 from public.installments i where i.member_id=m.id and i.attempt_count>=2)
    and exists (select 1 from public.installments i where i.member_id=m.id and i.status not in ('paid','waived') and i.due_date<current_date)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, amount_cents=excluded.amount_cents, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (3) staffing_gap: session in next 14d with no assigned staff --------------
  if public.agent_read_job_allowed(p_provider,'staffing_gap',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, subject_type, subject_id, run_id)
  select pr.provider_id, 'schedule', 'staffing_gap',
    case when s.start_date <= current_date+3 then 'urgent' else 'attention' end,
    'No staff assigned — ' || coalesce(s.title, pr.title) || ' on ' || to_char(s.start_date,'Mon DD'),
    'A scheduled event in the next 14 days has no assigned staff member.',
    'finding:staffgap:' || s.id, 'session', s.id, v_run
  from public.sessions s
  join public.programs pr on pr.id = s.program_id
  where s.assigned_member_id is null and s.start_date between current_date and current_date+14
    and (p_provider is null or pr.provider_id=p_provider) and public.agent_read_on(pr.provider_id)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, severity=excluded.severity, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (4) booking_unconfirmed: session next 14d with no facility ----------------
  if public.agent_read_job_allowed(p_provider,'booking_unconfirmed',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, subject_type, subject_id, run_id)
  select pr.provider_id, 'schedule', 'booking_unconfirmed',
    case when s.start_date <= current_date+3 then 'urgent' else 'attention' end,
    'No location set — ' || coalesce(s.title, pr.title) || ' on ' || to_char(s.start_date,'Mon DD'),
    'A scheduled event in the next 14 days has no facility/address confirmed.',
    'finding:bookunconf:' || s.id, 'session', s.id, v_run
  from public.sessions s
  join public.programs pr on pr.id = s.program_id
  where (s.address is null or s.address='') and s.start_date between current_date and current_date+14
    and (p_provider is null or pr.provider_id=p_provider) and public.agent_read_on(pr.provider_id)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, severity=excluded.severity, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (5) schedule_conflict: same facility + date + start_time, two sessions ----
  if public.agent_read_job_allowed(p_provider,'schedule_conflict',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, run_id, evidence)
  select pr.provider_id, 'schedule', 'schedule_conflict', 'urgent',
    'Double-booked: ' || s.address || ' on ' || to_char(s.start_date,'Mon DD') || coalesce(' at '||s.start_time,''),
    'Two events share a facility and slot. Resolve before the date.',
    'finding:conflict:' || pr.provider_id || ':' || md5(s.address||s.start_date::text||coalesce(s.start_time,'')), v_run,
    jsonb_build_object('address', s.address, 'date', s.start_date, 'time', s.start_time)
  from public.sessions s
  join public.programs pr on pr.id=s.program_id
  where s.address is not null and s.start_date>=current_date
    and (p_provider is null or pr.provider_id=p_provider) and public.agent_read_on(pr.provider_id)
    and (select count(*) from public.sessions s2 join public.programs pr2 on pr2.id=s2.program_id
         where pr2.provider_id=pr.provider_id and s2.address=s.address and s2.start_date=s.start_date
           and coalesce(s2.start_time,'')=coalesce(s.start_time,'')) > 1
  group by pr.provider_id, s.address, s.start_date, s.start_time
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (6) roster_gap: team below target_size --------------------------------
  if public.agent_read_job_allowed(p_provider,'roster_gap',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, subject_type, subject_id, run_id, evidence)
  select t.provider_id, 'people', 'roster_gap', 'info',
    t.name || ' is below its target size (' || (select count(*) from public.team_athletes m where m.team_id=t.id and m.status='active') || ' of ' || t.target_size || ')',
    'This group is under its target headcount — a recruiting or reactivation opportunity.',
    'finding:rostergap:' || t.id, 'team', t.id, v_run,
    jsonb_build_object('target', t.target_size)
  from public.teams t
  where t.target_size is not null
    and (select count(*) from public.team_athletes m where m.team_id=t.id and m.status='active') < t.target_size
    and (p_provider is null or t.provider_id=p_provider) and public.agent_read_on(t.provider_id)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (7) missing_data: no DOB on an active member --------------------------
  if public.agent_read_job_allowed(p_provider,'missing_data',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, member_id, subject_type, subject_id, run_id, evidence)
  select m.provider_id, 'people', 'missing_data', 'info',
    m.first_name || ' ' || coalesce(m.last_name,'') || ' is missing a date of birth',
    'Required for age-group placement and some waivers.',
    'finding:missingdob:' || m.id, m.id, 'member', m.id, v_run,
    jsonb_build_object('missing', jsonb_build_array('dob'))
  from public.team_athletes m
  where m.status='active' and m.first_name is not null and m.dob is null
    and (p_provider is null or m.provider_id=p_provider) and public.agent_read_on(m.provider_id)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (8) waiver_drift: a signature bound to a superseded document version ---
  if public.agent_read_job_allowed(p_provider,'waiver_drift',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, member_id, subject_type, subject_id, run_id)
  select wd.provider_id, 'documents', 'waiver_drift', 'attention',
    m.first_name || ' ' || coalesce(m.last_name,'') || ' signed an old version of ' || wd.title,
    'Their signature is bound to a superseded document version; a re-sign may be required.',
    'finding:waiverdrift:' || ws.id, m.id, 'member', m.id, v_run
  from public.waiver_signatures ws
  join public.waiver_documents wd on wd.id = ws.waiver_document_id
  join public.team_athletes m on m.id = ws.member_id
  where ws.document_version < (select max(w2.version) from public.waiver_documents w2 where w2.provider_id=wd.provider_id and w2.title=wd.title)
    and (p_provider is null or wd.provider_id=p_provider) and public.agent_read_on(wd.provider_id)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (9) idle_capacity: program < 70% enrolled with a session <= 14d away ---
  if public.agent_read_job_allowed(p_provider,'idle_capacity',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, subject_type, subject_id, run_id, evidence)
  select pr.provider_id, 'clients', 'idle_capacity', 'attention',
    pr.title || ' is ' || round(100.0*pr.enrolled_count/nullif(pr.max_capacity,0)) || '% full with a start in ' || (min(s.start_date)-current_date) || ' days',
    'Under-enrolled with little time left — offer the open spots to existing families first.',
    'finding:idlecap:' || pr.id, 'program', pr.id, v_run,
    jsonb_build_object('enrolled', pr.enrolled_count, 'capacity', pr.max_capacity)
  from public.programs pr
  join public.sessions s on s.program_id = pr.id and s.start_date between current_date and current_date+14
  where pr.max_capacity > 0 and pr.enrolled_count::numeric/pr.max_capacity < 0.7
    and (p_provider is null or pr.provider_id=p_provider) and public.agent_read_on(pr.provider_id)
  group by pr.id
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (10) waitlist_match: active program waitlist + another program with room -
  if public.agent_read_job_allowed(p_provider,'waitlist_match',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, run_id, evidence)
  select pw.provider_id, 'clients', 'waitlist_match', 'info',
    coalesce(pw.athlete_first_name,'A family') || ' is waitlisted, but you have open capacity elsewhere',
    'Turn a lost inquiry into a booking by offering an open program in the same org.',
    'finding:waitmatch:' || pw.id, v_run,
    jsonb_build_object('waitlist_id', pw.id)
  from public.program_waitlist pw
  where pw.status='waiting'
    and exists (select 1 from public.programs pr where pr.provider_id=pw.provider_id and pr.max_capacity>pr.enrolled_count and pr.status='active')
    and (p_provider is null or pw.provider_id=p_provider) and public.agent_read_on(pw.provider_id)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (11) camp_to_program: a camp fee schedule but no team/current enrollment -
  if public.agent_read_job_allowed(p_provider,'camp_to_program',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, member_id, subject_type, subject_id, run_id)
  select fs.provider_id, 'clients', 'camp_to_program', 'info',
    m.first_name || ' ' || coalesce(m.last_name,'') || ' did a camp but never joined a program',
    'A camp attendee with no ongoing enrollment — a warm conversion candidate.',
    'finding:camp2prog:' || m.id, m.id, 'member', m.id, v_run
  from public.team_athletes m
  join public.fee_schedules fs on fs.member_id=m.id
  join public.programs pr on pr.id=fs.program_id and pr.offering_type='camp'
  where m.status='active'
    and (p_provider is null or fs.provider_id=p_provider) and public.agent_read_on(fs.provider_id)
    and not exists (select 1 from public.fee_schedules f2 join public.programs p2 on p2.id=f2.program_id
                    where f2.member_id=m.id and p2.offering_type<>'camp' and f2.status in ('active','complete'))
  group by fs.provider_id, m.id, m.first_name, m.last_name
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (12) collection_trend: this period collected/billed vs prior -----------
  if public.agent_read_job_allowed(p_provider,'collection_trend',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, run_id, evidence)
  select fs.provider_id, 'money', 'collection_trend',
    case when this_rate < prior_rate - 0.1 then 'attention' else 'info' end,
    'Collection rate ' || round(100*this_rate) || '% this month vs ' || round(100*prior_rate) || '% last',
    'Share of billed dues actually collected, month over month.',
    'finding:trend:' || fs.provider_id || ':' || to_char(current_date,'YYYY-MM'), v_run,
    jsonb_build_object('this', round(100*this_rate), 'prior', round(100*prior_rate))
  from (
    select fs.provider_id,
      coalesce(sum(i.amount_cents) filter (where i.status='paid' and i.due_date >= date_trunc('month',current_date)),0)::numeric
        / nullif(sum(i.amount_cents) filter (where i.due_date >= date_trunc('month',current_date)),0) as this_rate,
      coalesce(sum(i.amount_cents) filter (where i.status='paid' and i.due_date >= date_trunc('month',current_date)-interval '1 month' and i.due_date < date_trunc('month',current_date)),0)::numeric
        / nullif(sum(i.amount_cents) filter (where i.due_date >= date_trunc('month',current_date)-interval '1 month' and i.due_date < date_trunc('month',current_date)),0) as prior_rate
    from public.fee_schedules fs join public.installments i on i.fee_schedule_id=fs.id
    group by fs.provider_id
  ) fs
  where this_rate is not null and prior_rate is not null
    and (p_provider is null or fs.provider_id=p_provider) and public.agent_read_on(fs.provider_id)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, severity=excluded.severity, evidence=excluded.evidence, run_id=excluded.run_id, updated_at=now();
  end if;
  -- (13) org_structure: weekly snapshot ------------------------------------
  if public.agent_read_job_allowed(p_provider,'org_structure',p_force) then
  insert into public.agent_findings (provider_id, kind, code, severity, title, detail, source_ref, run_id, evidence)
  select p.id, 'people', 'org_structure', 'info',
    (select count(*) from public.teams t where t.provider_id=p.id) || ' groups · ' ||
    (select count(*) from public.team_athletes m where m.provider_id=p.id and m.status='active') || ' members · ' ||
    (select count(*) from public.organization_members om where om.organization_id=p.id and om.is_active) || ' staff',
    (select count(*) from public.team_athletes m where m.provider_id=p.id and m.status='active' and m.team_id is null) || ' member(s) not yet assigned to a group.',
    'finding:orgstruct:' || p.id || ':' || to_char(current_date,'IYYY-IW'), v_run,
    jsonb_build_object('unassigned', (select count(*) from public.team_athletes m where m.provider_id=p.id and m.status='active' and m.team_id is null))
  from public.providers p
  where (p_provider is null or p.id=p_provider) and public.agent_read_on(p.id)
    and exists (select 1 from public.team_athletes m where m.provider_id=p.id)
  on conflict (provider_id, source_ref) where status <> 'dismissed' do update set title=excluded.title, detail=excluded.detail, evidence=excluded.evidence, run_id=excluded.run_id, updated_at=now();
  end if;
  select count(distinct kind) into n from public.agent_findings where run_id = v_run;
  return n;
end; $function$;
-- Triggered READ is owner-only and plan-gated. The dedicated treasurer and
-- proposal cron entrypoints are wrapped below with the same catalog boundary.
create or replace function public.run_agent_read(p_provider uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare v integer:=0; v_run uuid:=gen_random_uuid(); v_scan_mode text;
begin
  if not exists (select 1 from public.providers where id=p_provider and owner_id=auth.uid()) then
    raise insufficient_privilege using message='only the org owner may run the agent';
  end if;
  -- Off or incomplete onboarding is not a pricing error: it simply has no
  -- agent work to run. A 402 is reserved for an otherwise enabled org whose
  -- purchased scan mode does not include a triggered run.
  if not public.agent_read_on(p_provider) then return 0; end if;
  v_scan_mode:=public.agent_entitlement(p_provider)->>'scan_mode';
  if v_scan_mode not in ('triggered','ondemand') then
    perform public.raise_agent_entitlement_402(p_provider,'agent_scan_mode',0,1);
  end if;
  v:=public.generate_agent_findings(p_provider,true);
  if public.agent_job_allowed(p_provider,'treasurer_summary','triggered') then
    perform public.generate_treasurer_summary(p_provider,true,v_run);
  end if;
  if public.agent_job_allowed(p_provider,'proposals','triggered') then
    perform public.generate_agent_proposals(p_provider,true);
  end if;
  return v;
end;
$$;
revoke all on function public.run_agent_read(uuid) from public,anon;
grant execute on function public.run_agent_read(uuid) to authenticated;

-- LIVE ENTRYPOINT EVIDENCE (read-only capture 2026-09-09): cron job 19 calls
-- generate_treasurer_summary() weekly and job 20 calls generate_agent_proposals()
-- nightly. Both were direct service-role-only functions, so guarding
-- run_agent_read alone left those cron paths outside the entitlement boundary.
-- Production pg_proc confirms these exact signatures/defaults:
--   generate_treasurer_summary(uuid,boolean,uuid)
--   generate_agent_proposals(uuid,boolean)
-- Renamed bodies receive false below; p_force is an invocation request only,
-- never a way to bypass mode, onboarding, jobs[], or scan_mode.
alter function public.generate_treasurer_summary(uuid,boolean,uuid)
  rename to generate_treasurer_summary_unentitled;
alter function public.generate_agent_proposals(uuid,boolean)
  rename to generate_agent_proposals_unentitled;
revoke all on function public.generate_treasurer_summary_unentitled(uuid,boolean,uuid),
  public.generate_agent_proposals_unentitled(uuid,boolean)
  from public,anon,authenticated,service_role;

create function public.generate_treasurer_summary(
  p_provider uuid default null,p_force boolean default false,p_run uuid default null
) returns integer language plpgsql security definer set search_path='' as $$
declare n integer:=0; p record; invocation text:=case when p_force then 'triggered' else 'nightly' end;
begin
  if p_provider is null then
    for p in select id from public.providers order by id loop
      n:=n+public.generate_treasurer_summary(p.id,p_force,p_run);
    end loop;
    return n;
  end if;
  if not public.agent_read_on(p_provider) then return 0; end if;
  if not public.agent_job_allowed(p_provider,'treasurer_summary',invocation) then
    if p_force then perform public.raise_agent_entitlement_402(p_provider,'agent_scan_mode',0,1); end if;
    return 0;
  end if;
  return public.generate_treasurer_summary_unentitled(p_provider,false,p_run);
end;
$$;

create function public.generate_agent_proposals(
  p_provider uuid default null,p_force boolean default false
) returns integer language plpgsql security definer set search_path='' as $$
declare n integer:=0; p record; invocation text:=case when p_force then 'triggered' else 'nightly' end;
begin
  if p_provider is null then
    for p in select id from public.providers order by id loop
      n:=n+public.generate_agent_proposals(p.id,p_force);
    end loop;
    return n;
  end if;
  if not public.agent_autodraft_on(p_provider) then return 0; end if;
  if not public.agent_job_allowed(p_provider,'proposals',invocation) then
    if p_force then perform public.raise_agent_entitlement_402(p_provider,'agent_scan_mode',0,1); end if;
    return 0;
  end if;
  return public.generate_agent_proposals_unentitled(p_provider,false);
end;
$$;

-- Preserve the live access contract: anonymous and browser roles cannot call
-- these service entrypoints; the scheduler/service role can call only wrappers.
revoke all on function public.generate_treasurer_summary(uuid,boolean,uuid),
  public.generate_agent_proposals(uuid,boolean) from public,anon,authenticated;
grant execute on function public.generate_treasurer_summary(uuid,boolean,uuid),
  public.generate_agent_proposals(uuid,boolean) to service_role;
commit;
