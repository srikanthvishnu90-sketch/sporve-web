# Incident runbook — Sporv (launch item 17)

One page. Who does what, with the exact command, when something breaks. The
uptime workflow (`.github/workflows/uptime.yml`) emails the owner on failure
every 15 minutes; everything below starts from that email or a user report.

## 0. First minute, every incident

1. Is it us or them? `curl -sI https://sporv.ai | head -1` and
   `curl -s -o /dev/null -w '%{http_code}\n' https://tseszaprvtvqrkfpditu.supabase.co/rest/v1/` — a 5xx from either is ours.
2. Note the time. Open `.clo-sync/activity.md` — if Codex or Claude deployed
   in the last hour, that is the first suspect.
3. Do not touch money tables by hand. Ever. Corrections are new ledger rows.

## 1. Site down / blank page (sporv.ai)

- Vercel → project **sporv1** → Deployments → open the latest → **Redeploy** the
  previous good build (the one whose `sporve-build` stamp matched the last
  verified merge). That is the rollback. ~2 minutes.
- If a fresh build is failing: `python3 src/build.py && bash src/smoke.sh`
  locally; the smoke output names the broken invariant.

## 2. Payments failing (checkout errors, webhook 5xx)

- Check the function: `supabase functions logs stripe-webhook --project-ref tseszaprvtvqrkfpditu`
  (or Supabase dashboard → Edge Functions → stripe-webhook → Logs).
- Stripe dashboard → Developers → Webhooks → the endpoint → **Recent deliveries**
  shows every event and Stripe's retry schedule (it retries for 3 days, so a
  short outage loses nothing).
- The ledger is append-only and idempotent on event id: re-delivery is safe.
  Never mark anything paid by hand — replay the event from Stripe instead
  (**Resend** on the delivery row).
- Rollback a bad function deploy: `supabase functions deploy stripe-webhook --project-ref tseszaprvtvqrkfpditu --no-verify-jwt` from the last good commit.

## 3. The agent drafted something wrong / sent something wrong

- Nothing sends without an approval click, so "sent something wrong" means an
  approved draft was wrong. Find it: Queue → Done, or
  `select * from outbound_messages where provider_id='…' order by created_at desc limit 20`.
- Stop the bleeding for one org: Settings → Automation → set the job to
  **Off** (writes `lifecycle_message_prefs.mode='off'`; the cron skips that org).
- Stop it for everyone (nuclear, owner-only): pause the three pg_cron jobs —
  `select cron.unschedule(jobname) from cron.job where jobname like 'agent%';`
- Re-run the golden set before re-enabling: `node scripts/agent-golden.mjs`
  must be green.

## 4. Email bouncing / going to spam

- Resend dashboard → Emails: bounce and complaint rates. Above 2% / 0.1%:
  freeze volume at the previous ramp tier (`docs/deliverability-ramp.md`).
- Suppressed addresses are automatic (`email_suppressions`); do not re-add them.
- DNS drift: `dig +short TXT send.sporv.ai` and `dig +short TXT resend._domainkey.sporv.ai`
  must both answer; `dig +short TXT _dmarc.sporv.ai` must show `p=quarantine`.

## 5. Data problem / need to restore

- Daily backups exist on the Pro plan (Supabase → Database → Backups).
  **Point-in-time recovery is OFF** — enabling it (Settings → Add-ons → PITR)
  is the owner's call and is recommended before the first real charge.
- Restoring is a dashboard action by the owner; announce a freeze in the
  ledger first (`python3 .claude/hooks/clo-sync.py begin claude "FREEZE: restore in progress"`).

## 6. Security event (leaked key, suspicious account)

- Rotate first, investigate second: Supabase → Settings → API → rotate anon /
  service keys; Resend → API keys → revoke; Stripe → Developers → API keys → roll.
- Vercel env vars (project sporv1) hold `SUPABASE_ANON_KEY` — update after a rotation.
- Then run `bash tools/strix-scan.sh` (needs Docker) or the clo pentest pass.

## Contacts and ownership

| what | owner |
|---|---|
| Vercel, GoDaddy DNS, Resend, Stripe, Supabase dashboards | Vishnu (owner) |
| Code rollback, function redeploy, smoke, golden set | Claude / Codex in session |
| Money-table changes | nobody by hand — new ledger rows only |
