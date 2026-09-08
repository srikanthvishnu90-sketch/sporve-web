-- RED DRAFT (migration; pg_cron) — rate-limit table garbage collection.
-- Launch item 18. Facts checked in prod 2026-09-08:
--   * public.edge_rate_limits already self-cleans: consume_edge_rate_limit()
--     deletes windows older than 2 days on ~1% of calls. That is fine at
--     pilot volume but is probabilistic — a quiet week never triggers it.
--   * public.waitlist_rate_limit(ip, ts) has NO cleanup at all: every
--     marketing-page waitlist submission leaves a row forever.
-- This adds one nightly deterministic sweep for both. No behaviour change
-- for callers; only rows older than the longest window (1 day) are removed.
-- Inverse: select cron.unschedule('sporv-rate-limit-gc'); drop function public.gc_rate_limits();
-- Verification: select jobname, schedule from cron.job where jobname='sporv-rate-limit-gc';
--   then next morning: select count(*) from public.waitlist_rate_limit where ts < now()-interval '2 days'; -- 0
begin;

create or replace function public.gc_rate_limits()
returns table (edge_deleted bigint, waitlist_deleted bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare e bigint; w bigint;
begin
  delete from public.edge_rate_limits where window_start < clock_timestamp() - interval '2 days';
  get diagnostics e = row_count;
  delete from public.waitlist_rate_limit where ts < clock_timestamp() - interval '2 days';
  get diagnostics w = row_count;
  return query select e, w;
end $$;

revoke all on function public.gc_rate_limits() from public, anon, authenticated;

select cron.schedule('sporv-rate-limit-gc', '55 3 * * *', $$ select public.gc_rate_limits(); $$);

commit;
