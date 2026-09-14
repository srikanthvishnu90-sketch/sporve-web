-- 20260910175643 — trigger-function EXECUTE revokes, refreshed for the trigger
-- functions added since 20260907_001034 (spec: 20260910_001044_new_trigger_function_grants).
-- [CRITICAL-PATH] Reconstructed 2026-09-14 from the live catalog
-- (project tseszaprvtvqrkfpditu); the migration is applied in the DB but was
-- missing from the repo. Follows the 001034 pattern: trigger and event-trigger
-- SECURITY DEFINER functions are not RPC endpoints, so client roles must not
-- hold EXECUTE on them. This pass sweeps every current public SECURITY DEFINER
-- trigger/event-trigger function (including newly added ones such as
-- connector_drop_secret_tg and the guardian guards) and revokes EXECUTE from
-- the API client roles. Trigger invocation is unaffected — triggers run as the
-- table owner regardless of client EXECUTE. service_role is intentionally left
-- as-is (the 001034 pass already stripped it from the older functions; the
-- newer ones keep their default service_role grant, which is harmless because
-- they are only ever reached as triggers).

do $$ declare f record;
begin
  for f in
    select distinct p.oid::regprocedure as signature
    from pg_trigger t join pg_proc p on p.oid=t.tgfoid
    join pg_namespace n on n.oid=p.pronamespace
    where not t.tgisinternal and n.nspname='public' and p.prosecdef
    union
    select distinct p.oid::regprocedure
    from pg_event_trigger e join pg_proc p on p.oid=e.evtfoid
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.signature);
  end loop;
end $$;
