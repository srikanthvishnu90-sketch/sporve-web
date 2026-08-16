select 'athlete consent fn'      as check,
       case when count(*)=1 then 'PASS' else 'FAIL' end as result
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='enforce_athlete_consent'
union all
select 'booking consent fn',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='enforce_booking_athlete_consent'
union all
select 'athlete trigger',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_trigger where tgname='trg_enforce_athlete_consent'
union all
select 'booking trigger',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_trigger where tgname='trg_enforce_booking_athlete_consent'
union all
select 'check constraint',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from pg_constraint where conname='athletes_consent_required'
union all
select 'no athlete lacks consent_version',
       case when count(*)=0 then 'PASS' else 'FAIL' end
  from public.athletes
 where consent_version is null or char_length(trim(consent_version))=0
union all
select 'no booking on an unconsented athlete',
       case when count(*)=0 then 'PASS' else 'FAIL' end
  from public.bookings b join public.athletes a on a.id=b.athlete_id
 where a.parent_consent is not true
union all
select 'ledger row recorded',
       case when count(*)=1 then 'PASS' else 'FAIL' end
  from supabase_migrations.schema_migrations where version='20260728000203';
