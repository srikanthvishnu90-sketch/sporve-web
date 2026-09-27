-- Empty disposable sporv_platform_billing_fixture ONLY; includes the actual
-- projection fixture and then this actual checkout draft. Never run in Supabase.
\set ON_ERROR_STOP on
\ir 2026-09-08-platform-billing.test.sql
alter table public.plan_entitlements add column purchasable boolean not null default true;
\ir 2026-09-08-platform-billing-checkout.sql

insert into public.providers(id,owner_id) values
 ('10000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000003');
insert into public.provider_entitlement_assignments(provider_id,plan_key,source,fallback_plan_key)
 values('10000000-0000-4000-8000-000000000003','free','legacy','free');
begin;
set local role service_role;
do $$
declare p uuid:='10000000-0000-4000-8000-000000000003'; r jsonb; a jsonb; request jsonb; revision bigint;
begin
  if public.register_platform_billing_customer(p,'cus_checkoutfixture',false)<>'cus_checkoutfixture' then
    raise exception 'FAIL: customer not registered'; end if;
  perform public.register_platform_billing_customer(p,'cus_checkoutfixture',false);
  begin
    perform public.register_platform_billing_customer(p,'cus_checkoutfixture',true);
    raise exception 'FAIL: mode switch allowed';
  exception when invalid_parameter_value then null; end;
  request:=jsonb_build_object('providerId',p,'livemode',false,'customerId','cus_checkoutfixture',
    'priceId','price_fixturemonth','requestId','40000000-0000-4000-8000-000000000001',
    'successUrl','https://sporv.ai/','cancelUrl','https://sporv.ai/','couponId',null);
  r:=public.reserve_platform_billing_checkout(request);
  if r->>'state'<>'pending' then raise exception 'FAIL: missing reservation'; end if;
  if public.reserve_platform_billing_checkout(request) is distinct from r then raise exception 'FAIL: retry changed reservation'; end if;
  begin
    perform public.reserve_platform_billing_checkout(jsonb_set(request,'{customerId}','"cus_fixture"'));
    raise exception 'FAIL: another customer was accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.reserve_platform_billing_checkout(jsonb_set(request,'{requestId}','"40000000-0000-4000-8000-000000000002"'));
    raise exception 'FAIL: second pending checkout allowed';
  exception when sqlstate 'PT409' then null; end;
  r:=public.record_platform_billing_checkout((request->>'requestId')::uuid,'cs_test_fixturecheckout',false);
  if r->>'stripe_checkout_session_id'<>'cs_test_fixturecheckout' then raise exception 'FAIL: session receipt missing'; end if;
  begin
    perform public.record_platform_billing_checkout((request->>'requestId')::uuid,'cs_test_different',false);
    raise exception 'FAIL: session identity overwritten';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.bind_platform_billing_checkout(false,'cs_test_fixturecheckout','cus_fixture','sub_checkoutfixture','price_fixturemonth');
    raise exception 'FAIL: checkout could bind another customer';
  exception when invalid_parameter_value then null; end;
  a:=public.bind_platform_billing_checkout(false,'cs_test_fixturecheckout','cus_checkoutfixture','sub_checkoutfixture','price_fixturemonth');
  if a->>'authorized'<>'true' or a->>'provider_id'<>p::text or a->>'subscription_id'<>'sub_checkoutfixture' then
    raise exception 'FAIL: subscription authorization receipt invalid'; end if;
  revision:=(a->>'projection_revision')::bigint;
  a:=public.bind_platform_billing_checkout(false,'cs_test_fixturecheckout','cus_checkoutfixture','sub_checkoutfixture','price_fixturemonth');
  if a->>'outcome'<>'duplicate' or (a->>'projection_revision')::bigint<>revision then raise exception 'FAIL: duplicate activation changed revision'; end if;
  begin
    perform public.retire_platform_billing_checkout((request->>'requestId')::uuid,'cs_test_fixturecheckout',false);
    raise exception 'FAIL: paid checkout retired';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.reserve_platform_billing_checkout(jsonb_set(request,'{requestId}','"40000000-0000-4000-8000-000000000002"'));
    raise exception 'FAIL: pending subscription allowed another checkout';
  exception when sqlstate 'PT409' then null; end;
  raise notice 'PASS: customer mode, tenant identity, request replay, one pending subscription, activation receipt and paid expiry denial';
end $$;
commit;

-- Suppress the final activation receipt to prove every preceding binding write
-- rolls back instead of returning a convincing but false success.
insert into public.providers(id,owner_id) values
 ('10000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000004');
select public.register_platform_billing_customer('10000000-0000-4000-8000-000000000004','cus_rollbackfixture',false);
select public.reserve_platform_billing_checkout(jsonb_build_object('providerId','10000000-0000-4000-8000-000000000004',
 'livemode',false,'customerId','cus_rollbackfixture','priceId','price_fixturemonth','requestId','40000000-0000-4000-8000-000000000004',
 'successUrl','https://sporv.ai/','cancelUrl','https://sporv.ai/','couponId',null));
select public.record_platform_billing_checkout('40000000-0000-4000-8000-000000000004','cs_test_rollbackfixture',false);
create function public.fixture_suppress_checkout() returns trigger language plpgsql as $$ begin return null; end $$;
create trigger suppress_checkout before update on public.platform_billing_checkout_reservations for each row execute function public.fixture_suppress_checkout();
do $$ declare before_revision bigint; begin
  select projection_revision into before_revision from public.platform_billing_provider_bindings where provider_id='10000000-0000-4000-8000-000000000004';
  begin
    perform public.bind_platform_billing_checkout(false,'cs_test_rollbackfixture','cus_rollbackfixture','sub_rollbackfixture','price_fixturemonth');
    raise exception 'FAIL: suppressed activation acknowledged';
  exception when object_not_in_prerequisite_state then null; end;
  if exists(select 1 from public.platform_billing_subscription_authorizations where stripe_subscription_id='sub_rollbackfixture')
    or (select projection_revision from public.platform_billing_provider_bindings where provider_id='10000000-0000-4000-8000-000000000004')<>before_revision then
    raise exception 'FAIL: suppressed activation left partial state'; end if;
  raise notice 'PASS: missing activation receipt rolls back authorization and revision';
end $$;
drop trigger suppress_checkout on public.platform_billing_checkout_reservations;
select public.retire_platform_billing_checkout('40000000-0000-4000-8000-000000000004','cs_test_rollbackfixture',false);
do $$ begin
  if (select state from public.platform_billing_checkout_reservations where request_id='40000000-0000-4000-8000-000000000004')<>'expired' then
    raise exception 'FAIL: verified unpaid expiry missing'; end if;
  if has_table_privilege('authenticated','public.platform_billing_checkout_reservations','SELECT,INSERT,UPDATE,DELETE')
    or has_function_privilege('authenticated','public.bind_platform_billing_checkout(boolean,text,text,text,text)','EXECUTE')
    or has_function_privilege('anon','public.register_platform_billing_customer(uuid,text,boolean)','EXECUTE') then
    raise exception 'FAIL: browser can mutate platform checkout state'; end if;
  raise notice 'PASS: expired session receipt and browser privilege denial';
end $$;
