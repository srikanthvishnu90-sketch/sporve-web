select 'safety predicate fn' as check,
       case when count(*)=1 then 'PASS' else 'FAIL' end as result
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='provider_safety_cleared'
union all
select 'booking verified trigger',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_trigger where tgname='trg_enforce_booking_provider_verified'
union all
select 'providers policy gated',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_policies where schemaname='public' and policyname='providers_select_public'
   and qual like '%provider_safety_cleared%'
union all
select 'programs policy gated',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_policies where schemaname='public' and policyname='programs_select_public'
   and qual like '%provider_safety_cleared%'
union all
select 'search gated',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='search_candidates'
   and pg_get_functiondef(p.oid) like '%provider_safety_cleared%'
union all
select 'bgcheck column now server-controlled',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='enforce_provider_trust'
   and pg_get_functiondef(p.oid) like '%background_check_status%'
union all
select 'visible providers (expect 20 of 23)',
       count(*)::text
  from public.providers
 where status='approved' and public.provider_safety_cleared(id)
union all
select 'ledger row recorded',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from supabase_migrations.schema_migrations where version='20260728000000';
