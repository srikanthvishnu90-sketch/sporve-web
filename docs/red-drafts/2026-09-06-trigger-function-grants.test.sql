-- Isolated regression fixture for the actual trigger-grant migration.
-- Run as the disposable cluster's superuser (event triggers require it):
-- createdb sporv_trigger_grants_test
-- psql -X -v ON_ERROR_STOP=1 -d sporv_trigger_grants_test -f THIS_FILE
-- Never run against Supabase/production. All fixtures and roles roll back.
\set ON_ERROR_STOP on
begin;
do $$ begin
  if current_database() <> 'sporv_trigger_grants_test' then
    raise exception 'Run only in the disposable sporv_trigger_grants_test database';
  end if;
  if exists (select 1 from pg_tables where schemaname='public')
     or exists (select 1 from pg_namespace where nspname='auth')
     or exists (select 1 from pg_event_trigger)
     or exists (select 1 from pg_roles where rolname in ('anon','authenticated','service_role')) then
    raise exception 'Fixture requires an empty database and isolated cluster roles';
  end if;
  if not (select rolsuper from pg_roles where rolname=current_user) then
    raise exception 'Disposable superuser required for event-trigger fixture';
  end if;
end $$;

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
grant usage on schema public to anon,authenticated,service_role;
create table public.fixture_calls (kind text not null);
create table public.fixture_rows (id integer primary key);
create function public.fixture_row_trigger() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  insert into public.fixture_calls values ('row');
  return new;
end $$;
create trigger fixture_row_write after insert on public.fixture_rows
for each row execute function public.fixture_row_trigger();
grant insert on public.fixture_rows to authenticated;

-- Create unaffected functions BEFORE the migration, so an overbroad revoke
-- would fail. An assertion on an RPC created afterwards proved nothing.
create function public.sporv_rpc_fixture() returns integer
language sql immutable as $$ select 1 $$;
create function public.fixture_unattached_definer() returns trigger
language plpgsql security definer set search_path='' as $$ begin return new; end $$;
create function public.fixture_invoker_trigger() returns trigger
language plpgsql set search_path='' as $$ begin return new; end $$;
create trigger fixture_invoker before insert on public.fixture_rows
for each row execute function public.fixture_invoker_trigger();
grant execute on function public.sporv_rpc_fixture(), public.fixture_unattached_definer(),
  public.fixture_invoker_trigger() to anon,authenticated,service_role;

-- The actual migration replaces this deliberately permissive old body.
create table public.payment_event_ledger (id integer primary key, amount integer not null);
insert into public.payment_event_ledger values (1,5000);
create function public.ledger_is_append_only() returns trigger
language plpgsql security definer as $$ begin return old; end $$;
create trigger fixture_ledger_guard before update or delete on public.payment_event_ledger
for each row execute function public.ledger_is_append_only();
grant select,insert,update,delete on public.payment_event_ledger to anon,authenticated,service_role;
create function public.fixture_ddl_trigger() returns event_trigger
language plpgsql security definer set search_path='' as $$
begin insert into public.fixture_calls values ('ddl'); end $$;
create event trigger fixture_ddl on ddl_command_end execute function public.fixture_ddl_trigger();
grant execute on function public.fixture_row_trigger(), public.fixture_ddl_trigger(),
  public.ledger_is_append_only() to anon,authenticated,service_role;

do $$
declare v_role text; v_function text;
begin
  foreach v_role in array array['anon','authenticated','service_role'] loop
    foreach v_function in array array['public.fixture_row_trigger()',
      'public.fixture_ddl_trigger()','public.ledger_is_append_only()'] loop
      if not has_function_privilege(v_role,v_function,'execute') then
        raise exception 'Preflight fixture is not permissive: % %',v_role,v_function;
      end if;
    end loop;
  end loop;
  raise notice 'PASS: self-contained permissive row/event/ledger preflight';
end $$;

-- Test source, not a duplicated revoke loop that could drift from production.
\ir ../../supabase/migrations/20260907_001034_trigger_function_grants.sql

do $$
declare v_role text; v_function text;
begin
  foreach v_role in array array['anon','authenticated','service_role'] loop
    foreach v_function in array array['public.fixture_row_trigger()',
      'public.fixture_ddl_trigger()','public.ledger_is_append_only()'] loop
      if has_function_privilege(v_role,v_function,'execute') then
        raise exception 'API execute remains: % %',v_role,v_function;
      end if;
      if exists (select 1 from pg_proc p,
        lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where p.oid=v_function::regprocedure and a.grantee=0 and a.privilege_type='EXECUTE') then
        raise exception 'PUBLIC execute remains: %',v_function;
      end if;
    end loop;
    foreach v_function in array array['public.sporv_rpc_fixture()',
      'public.fixture_unattached_definer()','public.fixture_invoker_trigger()'] loop
      if not has_function_privilege(v_role,v_function,'execute') then
        raise exception 'Out-of-scope function changed: % %',v_role,v_function;
      end if;
    end loop;
  end loop;
  if not exists (select 1 from pg_proc where oid='public.ledger_is_append_only()'::regprocedure
      and prosecdef and 'search_path=""'=any(proconfig)) then
    raise exception 'Ledger definer search path was not pinned';
  end if;
  raise notice 'PASS: exact revokes, PUBLIC removal, unaffected RPCs and pinned ledger path';
end $$;

set local role authenticated;
insert into public.fixture_rows values (1);
select public.sporv_rpc_fixture();
reset role;
do $$ begin
  if (select count(*) from public.fixture_calls where kind='row')<>1 then
    raise exception 'Attached trigger stopped executing after API revoke';
  end if;
  raise notice 'PASS: normal authenticated DML still invokes the attached trigger';
end $$;

-- Capture after migration DDL; a revoked event trigger must still execute.
do $$ begin
  perform set_config('sporv_fixture.ddl_before',
    (select count(*)::text from public.fixture_calls where kind='ddl'),true);
end $$;
create table public.fixture_ddl_probe (id integer);
do $$ begin
  if (select count(*) from public.fixture_calls where kind='ddl')<>
    current_setting('sporv_fixture.ddl_before')::integer+1 then
    raise exception 'Event-trigger invocation changed after API revoke';
  end if;
  raise notice 'PASS: event trigger remains attached and executes';
end $$;

do $$
declare v_role text;
begin
  -- Roles have table privileges: only SQLSTATE55000 from the actual trigger
  -- counts as success, not an unrelated privilege-denied error.
  foreach v_role in array array[current_user::text,'anon','authenticated','service_role'] loop
    execute format('set local role %I',v_role);
    begin
      update public.payment_event_ledger set amount=1 where id=1;
      raise exception 'Ledger update unexpectedly succeeded as %',v_role;
    exception when sqlstate '55000' then null; end;
    begin
      delete from public.payment_event_ledger where id=1;
      raise exception 'Ledger delete unexpectedly succeeded as %',v_role;
    exception when sqlstate '55000' then null; end;
    reset role;
  end loop;
  if (select count(*) from public.payment_event_ledger)<>1
    or not exists (select 1 from public.payment_event_ledger where id=1 and amount=5000) then
    raise exception 'Original ledger row changed';
  end if;
  raise notice 'PASS: owner and all API roles denied UPDATE/DELETE; original row unchanged';
end $$;
rollback;
