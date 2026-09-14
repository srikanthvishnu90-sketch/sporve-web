-- 20260910174531 — Gmail connector scan schedule (spec: 20260910_001041_gmail_scan_schedule).
-- Reconstructed 2026-09-14 from the live catalog (project tseszaprvtvqrkfpditu);
-- the migration is applied in the DB but was missing from the repo. Every 15
-- minutes a pg_cron job POSTs the gmail-scan edge function, authenticated with
-- the vaulted cron_secret, and records the request in cron_http_audit so
-- cron-http-health (job 6) can see it fail.

create or replace function public.invoke_gmail_scan()
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_url text; v_key text; v_req bigint;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'cron_secret';
  if v_url is null or v_url = '' or v_key is null or v_key = '' then
    raise log 'invoke_gmail_scan: vault secrets project_url/cron_secret missing';
    return;
  end if;

  select net.http_post(
    url     => v_url || '/functions/v1/gmail-scan',
    headers => jsonb_build_object(
                 'Content-Type','application/json',
                 'Authorization','Bearer ' || v_key),
    body    => '{}'::jsonb) into v_req;

  -- Same audit table as every other cron HTTP call, so cron-http-health
  -- (job 6) can see this one fail rather than only the older ones.
  insert into public.cron_http_audit (job_name, request_id)
  values ('gmail-scan', v_req);
end $function$;

revoke all on function public.invoke_gmail_scan() from public, anon, authenticated;
grant execute on function public.invoke_gmail_scan() to service_role;

-- Schedule every 15 minutes (idempotent: unschedule any prior job of this name).
do $$
begin
  begin
    perform cron.unschedule(jobid) from cron.job where jobname = 'sporv-gmail-scan';
    perform cron.schedule('sporv-gmail-scan', '*/15 * * * *',
      $job$ select public.invoke_gmail_scan(); $job$);
  exception when others then
    raise notice 'pg_cron unavailable (%)', sqlerrm;
  end;
end $$;
