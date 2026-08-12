-- ============================================================================
-- FIX: lifecycle-process has been 403ing on every cron tick
-- ============================================================================
-- SYMPTOM
--   pg_cron job 'lifecycle-process' runs every minute. cron.job_run_details
--   reports "succeeded" 63,321 times. Every actual HTTP call returns 403.
--
-- ROOT CAUSE
--   lifecycle-process/index.ts:157 compares the caller's bearer token to the
--   function's own SUPABASE_SERVICE_ROLE_KEY:
--
--       if (bearer !== SERVICE_ROLE_KEY) return 403
--
--   The cron gets that bearer from Vault:
--
--       select decrypted_secret from vault.decrypted_secrets
--        where name = 'service_role_key'
--
--   Vault's copy is a LEGACY JWT (prefix 'eyJhbGc', 219 chars), written
--   2026-06-29 and NEVER UPDATED. The key the function actually holds has
--   since changed. They no longer match, so every tick is rejected.
--
-- WHY NOBODY NOTICED
--   pg_cron records whether the SQL STATEMENT ran, not what the HTTP request it
--   fired returned. pg_net is asynchronous: invoke_lifecycle_process() queues
--   the request and returns immediately, so the job "succeeds" while the call
--   fails. 63,321 green ticks over a dead endpoint.
--
-- IMPACT
--   Every booking reminder, rebook nudge and lifecycle message queued in
--   outbound_messages has gone unsent for as long as this has been broken.
--
-- ============================================================================
-- STEP 1 · GET THE CURRENT SERVICE-ROLE KEY
--   https://supabase.com/dashboard/project/tseszaprvtvqrkfpditu/settings/api-keys
--   Copy the **service_role / secret** key. NOT the publishable/anon one —
--   pasting the publishable key here leaves the cron broken in a way that looks
--   fixed.
--
-- STEP 2 · Replace PASTE_KEY_HERE below and run it in the SQL editor.
--   The key never passes through a chat window this way.
-- ============================================================================

select vault.update_secret(
  (select id from vault.secrets where name = 'service_role_key'),
  'PASTE_KEY_HERE',
  'service_role_key',
  'Service-role key for pg_cron -> Edge Function calls. MUST be re-pasted after every key rotation, or every cron tick 403s silently while pg_cron still reports success.'
);

-- ============================================================================
-- STEP 3 · VERIFY — run separately, about 90 seconds later.
--   Two ticks must have fired. Expect status_code 200.
-- ============================================================================
-- select status_code, count(*) as n, max(created) as latest
--   from net._http_response
--  where created > now() - interval '3 minutes'
--  group by status_code;
--
-- 200 = fixed. 403 = the pasted key still does not match the function's.
-- Empty = no tick yet; wait another minute.
