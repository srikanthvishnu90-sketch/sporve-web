-- Verify the expected type rejection left the fixture untouched.
-- This is deliberately a separate connection after psql aborts the migration.
\set ON_ERROR_STOP on
do $$
begin
  if current_database()<>'sporv_entitlement_fixture' then
    raise exception 'Requires disposable sporv_entitlement_fixture';
  end if;
  if (select array_agg(plan order by plan) from public.plan_entitlements)
    is distinct from array['enterprise','free','pro']::text[]
    or (select plan from public.providers where id='10000000-0000-4000-8000-000000000001')
      is distinct from 'pro'
    or (select count(*) from public.plan_entitlements where connectors='legacy-shape-sentinel')<>3
    or exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='plan_entitlements' and column_name='member_cap')
    or to_regclass('public.billing_policy') is not null
    or to_regclass('public.provider_entitlement_assignments') is not null
    or to_regprocedure('public.get_provider_entitlements(uuid)') is not null then
    raise exception 'FAIL: rejected connector type mutated catalog, provider or billing objects';
  end if;
  raise notice 'PASS: incompatible connector type rejected; three legacy rows, provider and schema unchanged';
end $$;
