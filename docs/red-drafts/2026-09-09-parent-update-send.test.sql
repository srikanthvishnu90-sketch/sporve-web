-- Run ONLY on an empty disposable cluster/database, never production.
-- createdb sporv_parent_send_test
-- psql -X -v ON_ERROR_STOP=1 -d sporv_parent_send_test -f THIS_FILE
-- Separate two-session race tests remain required; sequential replay is not
-- claimed as proof of concurrency. All identifiers and bodies here are fixtures.
\set ON_ERROR_STOP on
do $$ begin
  if current_database()<>'sporv_parent_send_test' or exists(select 1 from pg_tables where schemaname='public') then
    raise exception 'Requires empty disposable sporv_parent_send_test database';
  end if;
end $$;
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create table public.providers(id uuid primary key,owner_id uuid not null);
create table public.plan_entitlements(plan text primary key,public_slug text unique not null,
  sort_order integer not null,purchasable boolean not null,send_quota_month integer not null,branding_footer boolean not null);
create table public.provider_entitlement_assignments(provider_id uuid primary key,plan_key text not null);
create function public.resolve_provider_entitlements_internal(p_provider uuid) returns jsonb language sql as $$
  select jsonb_build_object('effective_plan',plan_key) from public.provider_entitlement_assignments where provider_id=p_provider
$$;
create table public.athletes(id uuid primary key,parent_id uuid not null,first_name text not null);
create table public.team_athletes(id uuid primary key default gen_random_uuid(),provider_id uuid not null,athlete_id uuid);
create table public.programs(id uuid primary key,provider_id uuid not null);
create table public.sessions(id uuid primary key,program_id uuid not null);
create table public.bookings(id uuid primary key,program_id uuid,session_id uuid not null,
  athlete_id uuid,searcher_id uuid not null,status text not null);
create table public.parent_updates(id uuid primary key default gen_random_uuid(),provider_id uuid not null,child_id uuid,
  booking_id uuid,summary_body text,status text not null default 'draft',approved_by uuid,approved_at timestamptz,
  sent_at timestamptz,delivery_channel text);
create table public.notifications(id uuid primary key default gen_random_uuid(),user_id uuid not null,title text,message text);
create table public.outbound_messages(id uuid primary key default gen_random_uuid(),provider_id uuid not null,sent_at timestamptz,
  child_id uuid,booking_id uuid,event_type text not null default 'dues_reminder',content jsonb,status text not null default 'drafted',
  approved_by uuid,approved_at timestamptz,provider text);
create table public.guardians(id uuid primary key,provider_id uuid not null,user_id uuid,email text,email_status text);
\ir 2026-09-09-send-quota.sql
\ir 2026-09-09-parent-update-send.sql
\ir 2026-09-09-lifecycle-approval.sql
\ir 2026-09-09-lifecycle-inbox-delivery.sql

insert into public.plan_entitlements values('free','free',0,false,20,true),('solo','solo',1,true,-1,false),('organization','organization',2,true,-1,false);
insert into public.providers values('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002');
insert into public.provider_entitlement_assignments select id,'free' from public.providers;
insert into public.athletes values('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','Fixture'),
  ('20000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000002','Other family');
insert into public.programs select id,id from public.providers;
insert into public.sessions select id,id from public.programs;
insert into public.bookings values('40000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','completed');
create function public.fixture_update(p_body text default 'Approved fixture') returns uuid language plpgsql as $$
declare v_id uuid; begin
  insert into public.parent_updates(provider_id,child_id,booking_id,summary_body,status,approved_by,approved_at)
  values('00000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
    '40000000-0000-0000-0000-000000000001',p_body,'approved','10000000-0000-0000-0000-000000000001',now()) returning id into v_id;
  return v_id;
end $$;

create function public.fixture_send(p_id uuid) returns jsonb language sql as $$
  select public.send_parent_update_entitled(p_id,'10000000-0000-0000-0000-000000000001')
$$;

-- One inbox row and one quota receipt; a repeat returns the same receipt.
do $$ declare v_id uuid:=public.fixture_update(); a jsonb; b jsonb; begin
  a:=public.fixture_send(v_id); b:=public.fixture_send(v_id);
  assert a->>'kind'='sent'; assert b->>'kind'='already_sent'; assert a->>'receipt_id'=b->>'receipt_id';
  assert (select count(*)=1 from public.notifications);
  assert (select count(*)=1 from public.inbox_send_receipts);
  assert (select count(*)=1 from public.message_send_quota_claims where state='accepted');
  assert (select count(*)=2 from public.message_send_quota_events);
  assert (select message like E'%\n\nSent via Sporv' from public.notifications);
  raise notice 'PASS accepted inbox + immutable receipt + replay + Free footer';
end $$;

-- Approval, tenancy, and family identity failures are mutation-free.
do $$ declare v_id uuid:=public.fixture_update(); before_count bigint; begin
  select count(*) into before_count from public.notifications;
  begin perform public.send_parent_update_entitled(v_id,'10000000-0000-0000-0000-000000000002');
    raise exception 'Expected owner denial'; exception when insufficient_privilege then null; end;
  update public.parent_updates set approved_by=null where id=v_id;
  begin perform public.fixture_send(v_id); raise exception 'Expected approval denial'; exception when sqlstate 'PT409' then null; end;
  update public.parent_updates set approved_by='10000000-0000-0000-0000-000000000001',child_id='20000000-0000-0000-0000-000000000002' where id=v_id;
  begin perform public.fixture_send(v_id); raise exception 'Expected family denial'; exception when sqlstate 'PT422' then null; end;
  update public.parent_updates set child_id='20000000-0000-0000-0000-000000000001',summary_body=' ' where id=v_id;
  begin perform public.fixture_send(v_id); raise exception 'Expected empty-body denial'; exception when sqlstate 'PT422' then null; end;
  begin update public.parent_updates set status='sent',sent_at=now(),delivery_channel='inbox' where id=v_id;
    raise exception 'Expected direct-write denial'; exception when insufficient_privilege then null; end;
  assert (select count(*)=before_count from public.notifications);
  raise notice 'PASS owner, approval, family, empty body and direct-write denial';
end $$;

-- Monthly quota includes old channel deliveries, rather than resetting on deploy.
insert into public.outbound_messages(provider_id,sent_at)
select '00000000-0000-0000-0000-000000000001',clock_timestamp() from generate_series(1,19);
do $$ declare v_id uuid:=public.fixture_update(); detail text; begin
  begin perform public.fixture_send(v_id); raise exception 'Expected quota denial';
  exception when sqlstate 'PT402' then
    get stacked diagnostics detail=pg_exception_detail;
    assert detail::jsonb='{"reason":"send_quota_month","current_plan":"free","upgrade_to":"solo","limit":20,"current":20}'::jsonb;
  end;
  assert (select status='approved' from public.parent_updates where id=v_id);
  assert (select count(*)=1 from public.inbox_send_receipts);
  update public.provider_entitlement_assignments set plan_key='organization' where provider_id='00000000-0000-0000-0000-000000000001';
  assert public.fixture_send(v_id)->>'kind'='sent';
  assert (select message not like '%Sent via Sporv' from public.notifications where id=(select notification_id from public.inbox_send_receipts where parent_update_id=v_id));
  raise notice 'PASS exact402, legacy usage, Organization unlimited and paid branding';
end $$;

-- The constitution supersedes the older paid 500-send cap. Verify Solo also
-- sends beyond that old limit, without changing the state of later fixtures.
begin;
update public.provider_entitlement_assignments set plan_key='solo'
  where provider_id='00000000-0000-0000-0000-000000000001';
insert into public.outbound_messages(provider_id,sent_at)
select '00000000-0000-0000-0000-000000000001',clock_timestamp() from generate_series(1,501);
do $$ declare v_id uuid:=public.fixture_update(); begin
  assert public.fixture_send(v_id)->>'kind'='sent';
  assert (select message not like '%Sent via Sporv' from public.notifications
    where id=(select notification_id from public.inbox_send_receipts where parent_update_id=v_id));
  raise notice 'PASS Solo has no monthly send cap beyond 500 and no Free footer';
end $$;
rollback;

-- A roster member needs no booking or team assignment; a named invalid booking
-- cannot borrow that relationship, and another organization's roster is denied.
do $$ declare v_id uuid:=public.fixture_update(); begin
  update public.parent_updates set booking_id=null where id=v_id;
  insert into public.team_athletes(provider_id,athlete_id) values('00000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001');
  begin perform public.fixture_send(v_id); raise exception 'Expected foreign roster denial'; exception when sqlstate 'PT422' then null; end;
  insert into public.team_athletes(provider_id,athlete_id) values('00000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001');
  update public.parent_updates set booking_id='40000000-0000-0000-0000-000000000099' where id=v_id;
  begin perform public.fixture_send(v_id); raise exception 'Expected named booking denial'; exception when sqlstate 'PT422' then null; end;
  update public.parent_updates set booking_id=null where id=v_id;
  assert public.fixture_send(v_id)->>'kind'='sent';
  raise notice 'PASS flat roster family, cross-org roster denial and no bad-booking fallback';
end $$;

-- A database trigger silently skipping a notification or the sent transition
-- must roll the entire operation back, including quota and notification rows.
create function public.fixture_skip() returns trigger language plpgsql as $$ begin return null; end $$;
create trigger fixture_skip_notification before insert on public.notifications for each row execute function public.fixture_skip();
do $$ declare v_id uuid:=public.fixture_update(); begin
  begin perform public.fixture_send(v_id); raise exception 'Expected missing notification failure'; exception when sqlstate 'PT503' then null; end;
  assert not exists(select 1 from public.inbox_send_receipts where parent_update_id=v_id);
  assert not exists(select 1 from public.message_send_quota_claims where source_kind='parent_update' and source_id=v_id);
end $$;
drop trigger fixture_skip_notification on public.notifications;
create trigger fixture_skip_transition before update on public.parent_updates for each row execute function public.fixture_skip();
do $$ declare v_id uuid:=public.fixture_update(); n bigint; begin
  select count(*) into n from public.notifications;
  begin perform public.fixture_send(v_id); raise exception 'Expected missing transition failure'; exception when sqlstate 'PT503' then null; end;
  assert (select count(*)=n from public.notifications);
  assert not exists(select 1 from public.inbox_send_receipts where parent_update_id=v_id);
  assert not exists(select 1 from public.message_send_quota_claims where source_kind='parent_update' and source_id=v_id);
  assert (select status='approved' from public.parent_updates where id=v_id);
  raise notice 'PASS silent no-op rolls back notification and quota';
end $$;

-- Shared reservations (including ambiguous/unconfirmed email) consume the same
-- allowance before any sent_at exists. Re-reserving is idempotent and a data
-- change to a limit is immediately authoritative, not a plan-name branch.
do $$ declare v_source uuid:=gen_random_uuid(); v_claim uuid; v_again uuid; detail text; begin
  v_claim:=public.reserve_message_send_quota_internal('00000000-0000-0000-0000-000000000002','outbound',v_source);
  v_again:=public.reserve_message_send_quota_internal('00000000-0000-0000-0000-000000000002','outbound',v_source);
  assert v_claim=v_again;
  assert (select count(*)=1 from public.message_send_quota_events where claim_id=v_claim and event='reserved');
  update public.plan_entitlements set send_quota_month=1 where public_slug='free';
  begin
    perform public.reserve_message_send_quota_internal('00000000-0000-0000-0000-000000000002','parent_update',gen_random_uuid());
    raise exception 'Expected shared reservation quota denial';
  exception when sqlstate 'PT402' then
    get stacked diagnostics detail=pg_exception_detail;
    assert detail::jsonb->>'current'='1'; assert detail::jsonb->>'limit'='1';
  end;
  begin
    perform public.reserve_message_send_quota_internal('00000000-0000-0000-0000-000000000001','outbound',v_source);
    raise exception 'Expected cross-org quota identity denial';
  exception when insufficient_privilege then null; end;
  assert not has_function_privilege('service_role','public.reserve_message_send_quota_internal(uuid,text,uuid)','execute');
  assert not has_function_privilege('authenticated','public.accept_message_send_quota_internal(uuid,uuid,uuid)','execute');
  assert (select relrowsecurity from pg_class where oid='public.message_send_quota_claims'::regclass);
  assert (select relrowsecurity from pg_class where oid='public.message_send_quota_events'::regclass);
  raise notice 'PASS shared reserved capacity, replay, data-only limit, tenant binding and internal grants';
end $$;
drop trigger fixture_skip_transition on public.parent_updates;

-- Grants/RLS/append-only, including privileged roles. No source RLS mock is
-- represented as production isolation proof; actual token tests remain open.
do $$ begin
  assert (select relrowsecurity from pg_class where oid='public.inbox_send_receipts'::regclass);
  assert not has_function_privilege('anon','public.send_parent_update_entitled(uuid,uuid)','execute');
  assert not has_function_privilege('authenticated','public.send_parent_update_entitled(uuid,uuid)','execute');
  assert has_function_privilege('service_role','public.send_parent_update_entitled(uuid,uuid)','execute');
  assert not has_table_privilege('service_role','public.inbox_send_receipts','insert');
  begin update public.inbox_send_receipts set accepted_at=now(); raise exception 'Expected immutable denial'; exception when sqlstate '55000' then null; end;
  begin delete from public.inbox_send_receipts; raise exception 'Expected delete denial'; exception when sqlstate '55000' then null; end;
  raise notice 'PASS RLS, RPC grants and append-only receipts';
end $$;

-- Lifecycle approval uses the same pool and atomically delivers claimed users.
do $$ declare v_id uuid:=gen_random_uuid(); initial jsonb:='{"body":"Reviewed fixture"}'; a jsonb; b jsonb; begin
  insert into public.outbound_messages(id,provider_id,child_id,booking_id,content)
    values(v_id,'00000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',initial);
  a:=public.approve_lifecycle_message_entitled(v_id,'10000000-0000-0000-0000-000000000001',initial,'Reviewed fixture','[]');
  b:=public.approve_lifecycle_message_entitled(v_id,'10000000-0000-0000-0000-000000000001',initial,'Reviewed fixture','[]');
  assert a->>'kind'='sent'; assert b->>'kind'='already_sent'; assert a->>'receipt_id'=b->>'receipt_id';
  assert (select count(*)=1 from public.outbound_inbox_send_receipts where message_id=v_id);
  assert (select count(*)=1 from public.message_send_quota_claims where source_kind='outbound' and source_id=v_id and state='accepted');
  raise notice 'PASS lifecycle atomic inbox, shared acceptance and replay';
end $$;

-- No silent approval of a stale body or a guardian belonging to another org.
insert into public.guardians values('60000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002',null,'family@example.invalid','ok');
do $$ declare v_id uuid:=gen_random_uuid(); initial jsonb:='{"body":"Reviewed fixture","guardian_id":"60000000-0000-0000-0000-000000000001"}'; begin
  insert into public.outbound_messages(id,provider_id,content) values(v_id,'00000000-0000-0000-0000-000000000001',initial);
  begin perform public.approve_lifecycle_message_entitled(v_id,'10000000-0000-0000-0000-000000000002',initial,'Reviewed fixture','[]');
    raise exception 'Expected foreign owner denial'; exception when insufficient_privilege then null; end;
  begin perform public.approve_lifecycle_message_entitled(v_id,'10000000-0000-0000-0000-000000000001','{}','Reviewed fixture','[]');
    raise exception 'Expected changed draft denial'; exception when sqlstate 'PT409' then null; end;
  begin perform public.approve_lifecycle_message_entitled(v_id,'10000000-0000-0000-0000-000000000001',initial,'Reviewed fixture','[]');
    raise exception 'Expected foreign guardian denial'; exception when sqlstate 'PT422' then null; end;
  assert (select status='drafted' and approved_by is null from public.outbound_messages where id=v_id);
  assert not exists(select 1 from public.message_send_quota_claims where source_kind='outbound' and source_id=v_id);
  raise notice 'PASS lifecycle owner, exact source and organization guardian preconditions';
end $$;

-- One existing ambiguous reservation in org2 plus this email fill a data-set
-- cap of two. A second approval gets402 before its approval can persist.
do $$ declare v_id uuid:=gen_random_uuid(); next_id uuid:=gen_random_uuid();
  initial jsonb:='{"body":"Reviewed fixture","guardian_id":"60000000-0000-0000-0000-000000000001"}';
  a jsonb; b jsonb; current_body jsonb; detail text; n bigint;
begin
  update public.plan_entitlements set send_quota_month=2 where public_slug='free';
  insert into public.outbound_messages(id,provider_id,content) values(v_id,'00000000-0000-0000-0000-000000000002',initial),
    (next_id,'00000000-0000-0000-0000-000000000002',initial);
  select count(*) into n from public.notifications;
  a:=public.approve_lifecycle_message_entitled(v_id,'10000000-0000-0000-0000-000000000002',initial,'Reviewed fixture','[]');
  select content into current_body from public.outbound_messages where id=v_id;
  b:=public.approve_lifecycle_message_entitled(v_id,'10000000-0000-0000-0000-000000000002',current_body,'Reviewed fixture','[]');
  assert a->>'kind'='queued_email'; assert a->>'quota_claim_id'=b->>'quota_claim_id';
  assert (select count(*)=n from public.notifications);
  assert (select status='approved' and sent_at is null from public.outbound_messages where id=v_id);
  begin perform public.approve_lifecycle_message_entitled(next_id,'10000000-0000-0000-0000-000000000002',initial,'Reviewed fixture','[]');
    raise exception 'Expected shared email reservation quota denial';
  exception when sqlstate 'PT402' then
    get stacked diagnostics detail=pg_exception_detail;
    assert detail::jsonb->>'current'='2'; assert detail::jsonb->>'limit'='2';
  end;
  assert (select status='drafted' and approved_by is null from public.outbound_messages where id=next_id);
  raise notice 'PASS queued email reserves but never claims delivery; replay and next approval402';
end $$;

create trigger fixture_skip_lifecycle_notification before insert on public.notifications for each row execute function public.fixture_skip();
do $$ declare v_id uuid:=gen_random_uuid(); initial jsonb:='{"body":"Reviewed fixture"}'; begin
  insert into public.outbound_messages(id,provider_id,child_id,booking_id,content)
    values(v_id,'00000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',initial);
  begin perform public.approve_lifecycle_message_entitled(v_id,'10000000-0000-0000-0000-000000000001',initial,'Reviewed fixture','[]');
    raise exception 'Expected notification no-op failure'; exception when sqlstate 'PT503' then null; end;
  assert (select status='drafted' and sent_at is null and approved_by is null from public.outbound_messages where id=v_id);
  assert not exists(select 1 from public.message_send_quota_claims where source_kind='outbound' and source_id=v_id);
  assert not exists(select 1 from public.outbound_inbox_send_receipts where message_id=v_id);
  assert not has_function_privilege('authenticated','public.approve_lifecycle_message_entitled(uuid,uuid,jsonb,text,jsonb)','execute');
  assert (select relrowsecurity from pg_class where oid='public.outbound_inbox_send_receipts'::regclass);
  raise notice 'PASS lifecycle silent no-op rollback, internal quota and service-only approval grants';
end $$;
drop trigger fixture_skip_lifecycle_notification on public.notifications;

-- Actual worker delivery-only transaction, not the human approval entrypoint.
-- Separate two-session races are still required; these are sequential SQL tests.
insert into public.guardians values('60000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',null,'unsubscribed');
update public.provider_entitlement_assignments set plan_key='organization'
  where provider_id='00000000-0000-0000-0000-000000000001';
create function public.fixture_approved_outbound() returns uuid language plpgsql as $$
declare v_id uuid; begin
  insert into public.outbound_messages(provider_id,content,status,approved_by,approved_at)
  values('00000000-0000-0000-0000-000000000001',
    '{"body":"Human approved inbox fixture","guardian_id":"60000000-0000-0000-0000-000000000002","removed":null}',
    'approved','10000000-0000-0000-0000-000000000001',clock_timestamp()-interval '1 minute') returning id into v_id;
  return v_id;
end $$;
create function public.fixture_worker_inbox(p_id uuid) returns jsonb language sql as $$
  select public.deliver_approved_lifecycle_inbox(id,provider_id,approved_by,approved_at,content,
    '30000000-0000-0000-0000-000000000001') from public.outbound_messages where id=p_id
$$;
do $$ declare v_id uuid:=public.fixture_approved_outbound(); a jsonb; b jsonb; t timestamptz; c jsonb; n bigint; begin
  select approved_at,content into t,c from public.outbound_messages where id=v_id;
  select count(*) into n from public.notifications;
  a:=public.fixture_worker_inbox(v_id); b:=public.fixture_worker_inbox(v_id);
  assert a->>'kind'='sent' and b->>'kind'='already_sent';
  assert a->>'receipt_id'=b->>'receipt_id';
  assert (select count(*)=n+1 from public.notifications);
  assert (select approved_at=t and content=c and approved_by='10000000-0000-0000-0000-000000000001'
    from public.outbound_messages where id=v_id);
  assert a->>'body_sha256'=encode(sha256(convert_to(c->>'body','UTF8')),'hex');
  assert (select count(*)=1 from public.message_send_quota_claims
    where source_kind='outbound' and source_id=v_id and state='accepted');
  raise notice 'PASS worker inbox shared quota, stable approval/body and receipt replay';
end $$;

do $$ declare v_id uuid:=public.fixture_approved_outbound(); m public.outbound_messages%rowtype; n bigint; begin
  select * into m from public.outbound_messages where id=v_id;
  select count(*) into n from public.notifications;
  update public.outbound_messages set status='drafted',approved_by=null,approved_at=null where id=v_id;
  begin perform public.deliver_approved_lifecycle_inbox(v_id,m.provider_id,m.approved_by,m.approved_at,m.content,
    '30000000-0000-0000-0000-000000000001');
    raise exception 'Worker unexpectedly approved a draft'; exception when sqlstate 'PT409' then null; end;
  assert (select status='drafted' and approved_by is null and approved_at is null from public.outbound_messages where id=v_id);
  update public.outbound_messages set status='approved',approved_by=m.approved_by,approved_at=m.approved_at where id=v_id;
  begin perform public.deliver_approved_lifecycle_inbox(v_id,'00000000-0000-0000-0000-000000000002',m.approved_by,m.approved_at,m.content,
    '30000000-0000-0000-0000-000000000001');
    raise exception 'Expected cross-org denial'; exception when insufficient_privilege then null; end;
  begin perform public.deliver_approved_lifecycle_inbox(v_id,m.provider_id,'10000000-0000-0000-0000-000000000002',m.approved_at,m.content,
    '30000000-0000-0000-0000-000000000001');
    raise exception 'Expected actor denial'; exception when insufficient_privilege then null; end;
  begin perform public.deliver_approved_lifecycle_inbox(v_id,m.provider_id,m.approved_by,m.approved_at+interval '1 second',m.content,
    '30000000-0000-0000-0000-000000000001');
    raise exception 'Expected approval timestamp denial'; exception when sqlstate 'PT409' then null; end;
  begin perform public.deliver_approved_lifecycle_inbox(v_id,m.provider_id,m.approved_by,m.approved_at,m.content||'{"body":"Changed"}',
    '30000000-0000-0000-0000-000000000001');
    raise exception 'Expected snapshot denial'; exception when sqlstate 'PT409' then null; end;
  begin perform public.deliver_approved_lifecycle_inbox(v_id,m.provider_id,m.approved_by,m.approved_at,m.content,
    '30000000-0000-0000-0000-000000000002');
    raise exception 'Expected family denial'; exception when sqlstate 'PT422' then null; end;
  assert (select count(*)=n from public.notifications);
  assert not exists(select 1 from public.message_send_quota_claims where source_kind='outbound' and source_id=v_id);
  raise notice 'PASS worker cannot approve, edit, borrow actor/org or change the claimed family';
end $$;

do $$ declare v_id uuid:=public.fixture_approved_outbound(); n bigint; begin
  select count(*) into n from public.notifications;
  update public.guardians set user_id='30000000-0000-0000-0000-000000000002'
    where id='60000000-0000-0000-0000-000000000002';
  begin perform public.fixture_worker_inbox(v_id); raise exception 'Expected changed guardian denial';
    exception when sqlstate 'PT422' then null; end;
  update public.guardians set user_id='30000000-0000-0000-0000-000000000001',
    provider_id='00000000-0000-0000-0000-000000000002' where id='60000000-0000-0000-0000-000000000002';
  begin perform public.fixture_worker_inbox(v_id); raise exception 'Expected foreign guardian denial';
    exception when sqlstate 'PT422' then null; end;
  update public.guardians set provider_id='00000000-0000-0000-0000-000000000001'
    where id='60000000-0000-0000-0000-000000000002';
  update public.outbound_messages set child_id='20000000-0000-0000-0000-000000000002',
    booking_id='40000000-0000-0000-0000-000000000001' where id=v_id;
  begin perform public.fixture_worker_inbox(v_id); raise exception 'Expected conflicting child denial';
    exception when sqlstate 'PT422' then null; end;
  assert (select count(*)=n from public.notifications);
  assert not exists(select 1 from public.message_send_quota_claims where source_kind='outbound' and source_id=v_id);
  raise notice 'PASS worker rechecks current guardian and actual child/booking identity';
end $$;

create trigger fixture_skip_worker_notification before insert on public.notifications for each row execute function public.fixture_skip();
do $$ declare v_id uuid:=public.fixture_approved_outbound(); begin
  begin perform public.fixture_worker_inbox(v_id); raise exception 'Expected worker missing notification failure';
    exception when sqlstate 'PT503' then null; end;
  assert (select status='approved' and sent_at is null from public.outbound_messages where id=v_id);
  assert not exists(select 1 from public.message_send_quota_claims where source_kind='outbound' and source_id=v_id);
  assert not exists(select 1 from public.outbound_inbox_send_receipts where message_id=v_id);
  raise notice 'PASS worker notification no-op rolls back quota and delivery';
end $$;
drop trigger fixture_skip_worker_notification on public.notifications;
create function public.fixture_corrupt_approval_time() returns trigger language plpgsql as $$
begin new.approved_at:=new.approved_at+interval '1 second'; return new; end $$;
create trigger fixture_corrupt_worker_transition before update on public.outbound_messages
  for each row execute function public.fixture_corrupt_approval_time();
do $$ declare v_id uuid:=public.fixture_approved_outbound(); n bigint; t timestamptz; begin
  select count(*) into n from public.notifications;
  select approved_at into t from public.outbound_messages where id=v_id;
  begin perform public.fixture_worker_inbox(v_id); raise exception 'Expected changed approval rollback';
    exception when sqlstate 'PT503' then null; end;
  assert (select approved_at=t and status='approved' and sent_at is null from public.outbound_messages where id=v_id);
  assert (select count(*)=n from public.notifications);
  assert not exists(select 1 from public.message_send_quota_claims where source_kind='outbound' and source_id=v_id);
  assert not exists(select 1 from public.outbound_inbox_send_receipts where message_id=v_id);
  raise notice 'PASS worker refuses a transaction that changes the original human approval';
end $$;
drop trigger fixture_corrupt_worker_transition on public.outbound_messages;
do $$ declare v_id uuid:=public.fixture_approved_outbound(); d text; begin
  update public.provider_entitlement_assignments set plan_key='free'
    where provider_id='00000000-0000-0000-0000-000000000001';
  update public.plan_entitlements set send_quota_month=0 where plan='free';
  begin perform public.fixture_worker_inbox(v_id); raise exception 'Expected worker402 from shared pool';
    exception when sqlstate 'PT402' then
      get stacked diagnostics d=pg_exception_detail;
      assert d::jsonb->>'reason'='send_quota_month' and d::jsonb->>'limit'='0';
  end;
  assert (select status='approved' and sent_at is null from public.outbound_messages where id=v_id);
  assert not exists(select 1 from public.message_send_quota_claims where source_kind='outbound' and source_id=v_id);
  assert has_function_privilege('service_role','public.deliver_approved_lifecycle_inbox(uuid,uuid,uuid,timestamptz,jsonb,uuid)','execute');
  assert not has_function_privilege('authenticated','public.deliver_approved_lifecycle_inbox(uuid,uuid,uuid,timestamptz,jsonb,uuid)','execute');
  assert not has_function_privilege('anon','public.deliver_approved_lifecycle_inbox(uuid,uuid,uuid,timestamptz,jsonb,uuid)','execute');
  raise notice 'PASS worker shared quota denial and service-only RPC grants';
end $$;

-- Regression: a reservation is not a permanent entitlement. Rechecks must
-- preserve accepted receipts but refuse an over-cap pending claim after a
-- downgrade and a previous-month claim with unknown external acceptance.
begin;
do $$
declare
  v_source uuid:=gen_random_uuid(); v_done_source uuid:=gen_random_uuid();
  v_claim uuid; v_done uuid; v_receipt uuid:=gen_random_uuid();
  v_before jsonb; v_detail text; v_failures text[]:='{}';
begin
  update public.provider_entitlement_assignments set plan_key='solo'
    where provider_id='00000000-0000-0000-0000-000000000002';
  v_claim:=public.reserve_message_send_quota_internal('00000000-0000-0000-0000-000000000002','outbound',v_source);
  v_done:=public.reserve_message_send_quota_internal('00000000-0000-0000-0000-000000000002','outbound',v_done_source);
  perform public.accept_message_send_quota_internal(v_done,'00000000-0000-0000-0000-000000000002',v_receipt);
  update public.provider_entitlement_assignments set plan_key='free'
    where provider_id='00000000-0000-0000-0000-000000000002';
  update public.plan_entitlements set send_quota_month=0 where plan='free';
  select to_jsonb(q) into v_before from public.message_send_quota_claims q where id=v_claim;
  begin
    perform public.reserve_message_send_quota_internal('00000000-0000-0000-0000-000000000002','outbound',v_source);
    v_failures:=array_append(v_failures,'pending claim bypassed downgraded quota');
  exception when sqlstate 'PT402' then
    get stacked diagnostics v_detail=pg_exception_detail;
    assert v_detail::jsonb->>'reason'='send_quota_month';
    assert v_detail::jsonb->>'current_plan'='free';
    assert v_detail::jsonb->>'upgrade_to'='solo';
    assert v_detail::jsonb->>'limit'='0';
    assert (v_detail::jsonb->>'current')::integer>0;
  end;
  assert (select to_jsonb(q)=v_before from public.message_send_quota_claims q where id=v_claim);
  assert public.reserve_message_send_quota_internal('00000000-0000-0000-0000-000000000002','outbound',v_done_source)=v_done;
  assert (select delivery_receipt_id=v_receipt and state='accepted' from public.message_send_quota_claims where id=v_done);

  update public.provider_entitlement_assignments set plan_key='solo'
    where provider_id='00000000-0000-0000-0000-000000000002';
  update public.message_send_quota_claims set
    reserved_at=(date_trunc('month',clock_timestamp() at time zone 'UTC')-interval '1 month') at time zone 'UTC',
    quota_month=(date_trunc('month',clock_timestamp() at time zone 'UTC')-interval '1 month')::date
    where id=v_claim;
  select to_jsonb(q) into v_before from public.message_send_quota_claims q where id=v_claim;
  begin
    perform public.reserve_message_send_quota_internal('00000000-0000-0000-0000-000000000002','outbound',v_source);
    v_failures:=array_append(v_failures,'previous-month claim reused without reconciliation');
  exception when sqlstate 'PT409' then null;
  end;
  assert (select to_jsonb(q)=v_before from public.message_send_quota_claims q where id=v_claim);
  assert (select count(*)=1 from public.message_send_quota_events where claim_id=v_claim);
  if cardinality(v_failures)>0 then raise exception '%',array_to_string(v_failures,'; '); end if;
  raise notice 'PASS existing pending reservation rechecks downgrade; old-month ambiguity blocked; accepted receipt unchanged';
end $$;
rollback;
