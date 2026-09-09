-- Disposable cluster ONLY. The shared fixture checks the database is empty
-- and named sporv_parent_send_test before creating any object or role.
\set ON_ERROR_STOP on
\ir 2026-09-09-parent-update-send.test.sql
alter table public.outbound_messages add column send_after timestamptz;
alter table public.outbound_messages add column attempt_count integer not null default 0;
alter table public.outbound_messages add column last_error text;
alter table public.outbound_messages add column provider_message_id text;
create table public.email_suppressions(email text primary key,reason text not null);
\ir 2026-09-09-lifecycle-email-delivery.sql

insert into public.providers values('00000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003');
insert into public.provider_entitlement_assignments values('00000000-0000-0000-0000-000000000003','solo');
insert into public.guardians values('50000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000003',null,'email-fixture@example.invalid','ok');
create function public.fixture_email() returns uuid language plpgsql as $$
declare v_id uuid; begin
  insert into public.outbound_messages(provider_id,content,status,approved_by,approved_at)
  values('00000000-0000-0000-0000-000000000003',jsonb_build_object('body','Approved fixture body','subject','Approved subject',
    'guardian_id','50000000-0000-0000-0000-000000000003'),'approved','10000000-0000-0000-0000-000000000003',clock_timestamp()) returning id into v_id;
  return v_id;
end $$;
create function public.fixture_prepare_email(p_id uuid) returns jsonb language sql as $$
  select public.prepare_approved_lifecycle_email(id,provider_id,approved_by,approved_at,content,
    'email-fixture@example.invalid','Fixture <fixture@mail.sporv.ai>','support@sporv.ai','Approved subject',
    'https://fixture.invalid/functions/v1/unsubscribe?g=50000000-0000-0000-0000-000000000003&t=00000000000000000000000000000000')
  from public.outbound_messages where id=p_id
$$;
create function public.fixture_email_result(p_dispatch jsonb,p_outcome text,p_provider_id text default null,p_after timestamptz default null)
returns jsonb language sql as $$
  select public.record_lifecycle_email_result((p_dispatch->>'dispatch_id')::uuid,(p_dispatch->>'attempt_id')::uuid,
    (p_dispatch->>'provider_id')::uuid,p_dispatch->>'wire_sha256',p_outcome,p_provider_id,p_after)
$$;

do $$ declare v_msg uuid:=public.fixture_email(); a jsonb; b jsonb; r jsonb; original jsonb; begin
  select content into original from public.outbound_messages where outbound_messages.id=v_msg;
  a:=public.fixture_prepare_email(v_msg); assert a->>'kind'='ready';
  assert (a->>'wire_body')::jsonb->>'text' like E'Approved fixture body\n\nUnsubscribe%';
  assert (a->>'wire_body')::jsonb->>'text' not like '%Sent via Sporv%';
  assert a->>'wire_sha256'=encode(sha256(convert_to(a->>'wire_body','UTF8')),'hex');
  assert (select state='reserved' from public.message_send_quota_claims where source_id=v_msg);
  b:=public.fixture_prepare_email(v_msg); assert b->>'kind'='held'; assert b->>'attempt_id'=a->>'attempt_id';
  assert (select count(*)=1 from public.outbound_email_attempts where dispatch_id=(a->>'dispatch_id')::uuid);
  r:=public.fixture_email_result(a,'accepted','provider-fixture-accepted');
  assert r->>'kind'='recorded';
  assert (select state='accepted' and delivery_receipt_id=(r->>'result_id')::uuid from public.message_send_quota_claims where source_id=v_msg);
  assert (select status='sent' and provider='resend' and provider_message_id='provider-fixture-accepted'
    and content=original from public.outbound_messages where outbound_messages.id=v_msg);
  assert public.fixture_email_result(a,'accepted','provider-fixture-accepted')->>'result_id'=r->>'result_id';
  assert public.fixture_prepare_email(v_msg)->>'kind'='already_accepted';
  begin perform public.fixture_email_result(a,'accepted','provider-fixture-conflict');
    raise exception 'Expected conflicting provider receipt denial'; exception when sqlstate 'PT409' then null; end;
  raise notice 'PASS email sealed wire + exclusive dispatch + atomic quota/acceptance + immutable replay';
end $$;

-- Guard failures cannot consume quota or alter the approved row.
begin;
do $$ declare v_msg uuid:=public.fixture_email(); m public.outbound_messages%rowtype; begin
  select * into m from public.outbound_messages where outbound_messages.id=v_msg;
  begin perform public.prepare_approved_lifecycle_email(v_msg,m.provider_id,'10000000-0000-0000-0000-000000000002',m.approved_at,m.content,
    'email-fixture@example.invalid','Fixture <fixture@mail.sporv.ai>','support@sporv.ai','Approved subject','https://fixture.invalid');
    raise exception 'Expected owner denial'; exception when insufficient_privilege then null; end;
  update public.outbound_messages set approved_at=null where outbound_messages.id=v_msg;
  begin perform public.fixture_prepare_email(v_msg); raise exception 'Expected approval denial'; exception when sqlstate 'PT409' then null; end;
  update public.outbound_messages set approved_at=m.approved_at where outbound_messages.id=v_msg;
  update public.guardians set email_status='bounced' where guardians.id='50000000-0000-0000-0000-000000000003';
  begin perform public.fixture_prepare_email(v_msg); raise exception 'Expected bounce denial'; exception when sqlstate 'PT422' then null; end;
  update public.guardians set email_status='ok',user_id='10000000-0000-0000-0000-000000000003' where guardians.id='50000000-0000-0000-0000-000000000003';
  begin perform public.fixture_prepare_email(v_msg); raise exception 'Expected claimed guardian email denial'; exception when sqlstate 'PT422' then null; end;
  update public.guardians set user_id=null,provider_id='00000000-0000-0000-0000-000000000002' where guardians.id='50000000-0000-0000-0000-000000000003';
  begin perform public.fixture_prepare_email(v_msg); raise exception 'Expected foreign guardian denial'; exception when sqlstate 'PT422' then null; end;
  update public.guardians set provider_id=m.provider_id where guardians.id='50000000-0000-0000-0000-000000000003';
  insert into public.email_suppressions values('email-fixture@example.invalid','fixture complaint');
  begin perform public.fixture_prepare_email(v_msg); raise exception 'Expected suppression denial'; exception when sqlstate 'PT422' then null; end;
  assert not exists(select 1 from public.message_send_quota_claims where source_id=v_msg);
  assert not exists(select 1 from public.outbound_email_dispatches where message_id=v_msg);
  assert (select status='approved' and sent_at is null from public.outbound_messages where outbound_messages.id=v_msg);
  raise notice 'PASS email owner/approval/claimed guardian/tenant/bounce/suppression denies without mutation';
end $$;
rollback;

begin;
do $$ declare v_msg uuid:=public.fixture_email(); a jsonb; b jsonb; later timestamptz:=clock_timestamp()+interval '2 minutes'; detail text; begin
  a:=public.fixture_prepare_email(v_msg);
  perform public.fixture_email_result(a,'retry_wait',null,later);
  assert public.fixture_prepare_email(v_msg)->>'kind'='deferred';
  -- Only the fixture superuser moves the due time; production callers cannot.
  update public.outbound_email_dispatches set retry_after=clock_timestamp()-interval '1 second' where message_id=v_msg;
  update public.outbound_messages set send_after=clock_timestamp()-interval '1 second' where outbound_messages.id=v_msg;
  update public.provider_entitlement_assignments set plan_key='free' where provider_id='00000000-0000-0000-0000-000000000003';
  begin perform public.fixture_prepare_email(v_msg); raise exception 'Expected retry downgrade402';
  exception when sqlstate 'PT402' then get stacked diagnostics detail=pg_exception_detail;
    assert detail::jsonb->>'reason'='send_quota_month'; assert detail::jsonb->>'limit'='0'; end;
  assert (select count(*)=1 from public.outbound_email_attempts where dispatch_id=(a->>'dispatch_id')::uuid);
  update public.provider_entitlement_assignments set plan_key='solo' where provider_id='00000000-0000-0000-0000-000000000003';
  b:=public.fixture_prepare_email(v_msg); assert b->>'kind'='ready'; assert b->>'attempt_id'<>a->>'attempt_id';
  assert b->>'wire_body'=a->>'wire_body'; assert b->>'idempotency_key'=a->>'idempotency_key';
  perform public.fixture_email_result(b,'ambiguous');
  assert public.fixture_prepare_email(v_msg)->>'kind'='held';
  assert (select state='reserved' from public.message_send_quota_claims where source_id=v_msg);
  begin perform public.fixture_email_result(b,'accepted','late-conflicting-receipt');
    raise exception 'Expected ambiguity reconciliation requirement'; exception when sqlstate 'PT409' then null; end;
  raise notice 'PASS429 retry is due-bound, downgrade-aware, byte/key-stable; ambiguous quota retained';
end $$;
rollback;

-- A provider acceptance after a downgrade still has to be recorded as fact.
begin;
do $$ declare v_msg uuid:=public.fixture_email(); a jsonb; begin
  a:=public.fixture_prepare_email(v_msg);
  update public.provider_entitlement_assignments set plan_key='free' where provider_id='00000000-0000-0000-0000-000000000003';
  perform public.fixture_email_result(a,'accepted','accepted-before-downgrade-fixture');
  assert public.fixture_prepare_email(v_msg)->>'kind'='already_accepted';
  raise notice 'PASS post-dispatch downgrade cannot erase real acceptance or reserve twice';
end $$;
rollback;

-- RLS, API grants and byte immutability ship with the tables, not later.
do $$ begin
  assert not exists(select 1 from pg_tables where schemaname='public' and tablename in
    ('outbound_email_dispatches','outbound_email_attempts','outbound_email_results') and not rowsecurity);
  assert not has_table_privilege('authenticated','public.outbound_email_dispatches','SELECT');
  assert not has_table_privilege('service_role','public.outbound_email_dispatches','UPDATE');
  assert not has_table_privilege('anon','public.outbound_email_results','SELECT');
  assert not has_function_privilege('authenticated','public.prepare_approved_lifecycle_email(uuid,uuid,uuid,timestamptz,jsonb,text,text,text,text,text)','EXECUTE');
  assert has_function_privilege('service_role','public.record_lifecycle_email_result(uuid,uuid,uuid,text,text,text,timestamptz)','EXECUTE');
  begin update public.outbound_email_dispatches set wire_body='{}'; raise exception 'Expected immutable wire denial'; exception when sqlstate '55000' then null; end;
  begin delete from public.outbound_email_results; raise exception 'Expected immutable result denial'; exception when sqlstate '55000' then null; end;
  raise notice 'PASS email RLS, role grants and immutable dispatch/results';
end $$;

-- An existing trigger that silently skips a write must abort the transaction.
begin;
create trigger fixture_skip_email_attempt before insert on public.outbound_email_attempts for each row execute function public.fixture_skip();
do $$ declare v_msg uuid:=public.fixture_email(); begin
  begin perform public.fixture_prepare_email(v_msg); raise exception 'Expected no-op attempt denial'; exception when sqlstate 'PT503' then null; end;
  assert not exists(select 1 from public.message_send_quota_claims where source_id=v_msg);
  assert not exists(select 1 from public.outbound_email_dispatches where message_id=v_msg);
  assert (select status='approved' from public.outbound_messages where outbound_messages.id=v_msg);
  raise notice 'PASS no-op email attempt rolls back quota and source transition';
end $$;
rollback;

begin;
create function public.fixture_alter_email_wire() returns trigger language plpgsql as $$ begin
  new.wire_body:='{"text":"not the approved body"}';
  new.wire_sha256:=encode(sha256(convert_to(new.wire_body,'UTF8')),'hex'); return new;
end $$;
create trigger fixture_alter_email_wire before insert on public.outbound_email_dispatches for each row execute function public.fixture_alter_email_wire();
do $$ declare v_msg uuid:=public.fixture_email(); begin
  begin perform public.fixture_prepare_email(v_msg); raise exception 'Dispatch accepted a trigger-altered wire payload';
    exception when sqlstate 'PT503' then null; end;
  assert not exists(select 1 from public.message_send_quota_claims where source_id=v_msg);
  raise notice 'PASS altered email wire cannot authorize a provider request';
end $$;
rollback;

begin;
update public.provider_entitlement_assignments set plan_key='free' where provider_id='00000000-0000-0000-0000-000000000003';
update public.plan_entitlements set send_quota_month=2 where plan='free';
do $$ declare v_msg uuid:=public.fixture_email(); a jsonb; v_extra uuid; detail text; begin
  a:=public.fixture_prepare_email(v_msg);
  assert (a->>'wire_body')::jsonb->>'text' like E'Approved fixture body\n\nSent via Sporv\n\nUnsubscribe%';
  v_extra:=public.fixture_email();
  begin perform public.fixture_prepare_email(v_extra); raise exception 'Expected shared send quota denial';
    exception when sqlstate 'PT402' then get stacked diagnostics detail=pg_exception_detail;
    assert detail::jsonb='{"reason":"send_quota_month","current_plan":"free","upgrade_to":"solo","limit":2,"current":2}'::jsonb; end;
  assert (select status='approved' and sent_at is null from public.outbound_messages where id=v_extra);
  raise notice 'PASS Free branding is catalog-driven; next email returns exact402 without deleting its draft';
end $$;
rollback;

begin;
create trigger fixture_skip_email_processing before update on public.outbound_messages for each row execute function public.fixture_skip();
do $$ declare v_msg uuid:=public.fixture_email(); begin
  begin perform public.fixture_prepare_email(v_msg); raise exception 'Expected no-op processing denial'; exception when sqlstate 'PT503' then null; end;
  assert not exists(select 1 from public.message_send_quota_claims where source_id=v_msg);
  assert not exists(select 1 from public.outbound_email_dispatches where message_id=v_msg);
  raise notice 'PASS no-op processing rolls back dispatch, attempt and quota';
end $$;
rollback;

begin;
do $$ declare v_msg uuid:=public.fixture_email(); a jsonb; n bigint; begin
  a:=public.fixture_prepare_email(v_msg);
  select count(*) into n from public.outbound_email_results;
  create trigger fixture_skip_email_result before insert on public.outbound_email_results for each row execute function public.fixture_skip();
  begin perform public.fixture_email_result(a,'accepted','missing-result-fixture'); raise exception 'Expected no-op result denial'; exception when sqlstate 'PT503' then null; end;
  assert (select count(*)=n from public.outbound_email_results);
  assert (select state='reserved' from public.message_send_quota_claims where source_id=v_msg);
  assert (select status='processing' and sent_at is null from public.outbound_messages where id=v_msg);
  drop trigger fixture_skip_email_result on public.outbound_email_results;
  create trigger fixture_skip_email_sent before update on public.outbound_messages for each row execute function public.fixture_skip();
  begin perform public.fixture_email_result(a,'accepted','missing-sent-fixture'); raise exception 'Expected no-op sent denial'; exception when sqlstate 'PT503' then null; end;
  assert (select count(*)=n from public.outbound_email_results);
  assert (select state='reserved' from public.message_send_quota_claims where source_id=v_msg);
  assert (select state='dispatching' from public.outbound_email_dispatches where message_id=v_msg);
  raise notice 'PASS no-op result/sent projection rolls back acceptance and preserves unknown dispatch';
end $$;
rollback;

begin;
create function public.fixture_alter_email_result() returns trigger language plpgsql as $$ begin
  new.provider_message_id:='not-the-provider-receipt'; return new;
end $$;
create trigger fixture_alter_email_result before insert on public.outbound_email_results for each row execute function public.fixture_alter_email_result();
do $$ declare v_msg uuid:=public.fixture_email(); a jsonb; begin
  a:=public.fixture_prepare_email(v_msg);
  begin perform public.fixture_email_result(a,'accepted','actual-provider-fixture'); raise exception 'Accepted a trigger-altered provider receipt';
    exception when sqlstate 'PT503' then null; end;
  assert not exists(select 1 from public.outbound_email_results where dispatch_id=(a->>'dispatch_id')::uuid);
  assert (select state='reserved' from public.message_send_quota_claims where source_id=v_msg);
  raise notice 'PASS altered provider receipt cannot mark the email sent';
end $$;
rollback;
