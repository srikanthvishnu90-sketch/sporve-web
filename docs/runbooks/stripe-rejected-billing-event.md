# Runbook — a Stripe billing event was REJECTED

**Symptom.** A row in `webhook_dead_letter` whose `error_msg` starts with
`REJECTED:` or `CRITICAL:`, and/or a `payment_event_ledger` row with
`outcome <> 'applied'`. Detection: `docs/queries/stripe-ledger-non-applied.sql`.

**What it means.** Stripe delivered the event, the signature verified, and
`apply_stripe_billing_event` ran — but declined to change the org's plan:

| verdict | cause | who fixes it |
|---|---|---|
| `REJECTED:ignored_bad_plan:<plan>` | subscription metadata `plan` is not one the RPC accepts (`pro`, `enterprise`) — e.g. the plan-key rename shipped before the RPC learned the new keys | engineering (plan gate) or ops (metadata) |
| `REJECTED:ignored_unknown_status:<status>` | a Stripe status the RPC does not map | engineering |
| `CRITICAL:provider_not_found` | the `provider_id` in subscription metadata matches no `providers` row — **a payment for an org that does not exist** | ops, immediately |

The event was acknowledged (200) **on purpose**: retrying cannot succeed because
the RPC has already recorded the event id, and a retry returns `duplicate`.
The dead-letter row is the durable record; the production-invariants job alarms
while it stays unresolved.

**Repair (owner-applied; agents never run this).**
1. Fix the cause (metadata / provider row / plan gate).
2. Apply `docs/red-drafts/2026-09-14-stripe-billing-event-reprocess.sql` once
   (adds the grant table + RPC; leaves the ledger append-only).
3. `select public.admin_grant_stripe_event_reprocess('evt_…', 'reason');`
4. Stripe Dashboard → Developers → Events → the event → **Resend**.
5. Verify: a new `payment_event_ledger` row with `outcome='applied'` whose
   `reverses_entry_id` = the original ignored row; `providers.plan` updated.
6. `update public.webhook_dead_letter set resolved_at = now() where stripe_event_id = 'evt_…';`
