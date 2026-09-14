-- Detection: every Stripe billing/booking event that did NOT apply, joined to
-- its dead letter if one was recorded. Read-only. NOT to be run by an agent
-- against production without the owner asking.
--
-- Columns: when it happened, the event, the ledger verdict class, the exact
-- handler verdict (from the dead letter, when present), how many times Stripe
-- delivered it, and whether anyone has resolved it.
select
  l.occurred_at,
  l.stripe_event_id,
  l.event_type,
  l.outcome                                   as ledger_outcome,     -- 'ignored' | anything not 'applied'
  d.error_msg                                 as handler_verdict,    -- 'REJECTED:…' | 'CRITICAL:…' | null (pre-fix silent 200)
  d.seen_count,
  d.first_seen_at,
  d.resolved_at,
  case
    when d.error_msg like 'CRITICAL:%'  then 'P1 — payment for a nonexistent org'
    when d.error_msg like 'REJECTED:%'  then 'P2 — operator fix then reprocess'
    when d.error_msg is null            then 'P2 — silent 200 era; no dead letter (pre-fix)'
    else                                     'P3 — see error_msg'
  end                                         as triage,
  l.stripe_object_id,
  l.amount_minor, l.currency, l.reverses_entry_id
from public.payment_event_ledger l
left join public.webhook_dead_letter d on d.stripe_event_id = l.stripe_event_id
where l.outcome <> 'applied'
order by (d.error_msg like 'CRITICAL:%') desc nulls last, l.occurred_at desc;

-- Companion: dead letters with NO ledger row at all (hard failures before the
-- RPC ran — signature, provider lookup, DB outage).
select d.*
from public.webhook_dead_letter d
left join public.payment_event_ledger l on l.stripe_event_id = d.stripe_event_id
where l.id is null and d.resolved_at is null
order by d.first_seen_at desc;
