-- 2026-09-14 — Reprocess a REJECTED Stripe billing event by stripe_event_id.
-- [CRITICAL-PATH: money] RED DRAFT. Owner applies by hand. NOT run by an agent.
--
-- WHY THIS EXISTS. apply_stripe_billing_event deliberately records EVERY verdict
-- — 'applied' AND the ignored ones (ignored_bad_plan, ignored_unknown_status,
-- provider_not_found) — in payment_event_ledger as a seen event. That is what
-- makes redelivery idempotent: the same stripe_event_id returns 'duplicate'.
-- The cost is that an event rejected for an OPERATOR reason (wrong plan key, a
-- provider row that had not been created yet) can never be replayed, even after
-- the operator fixes the cause. payment_event_ledger is append-only
-- (trg_ledger_append_only forbids UPDATE and DELETE), so the original row can
-- neither be edited nor removed. This draft adds a one-shot, audited GRANT that
-- lets the NEXT delivery of that exact event id bypass the duplicate check once.
--
-- Operator flow (docs/runbooks/stripe-rejected-billing-event.md):
--   1. fix the cause (plan metadata / provider row);
--   2. select public.admin_grant_stripe_event_reprocess('evt_…', 'why');
--   3. Stripe Dashboard → Developers → Events → that event → "Resend";
--   4. verify: ledger has a new 'applied' row whose reverses_entry_id points at
--      the original ignored row; providers.plan reflects it;
--   5. mark the webhook_dead_letter row resolved.

begin;

create table if not exists public.stripe_event_reprocess_grants (
  stripe_event_id text primary key,
  granted_by      uuid,
  granted_at      timestamptz not null default now(),
  consumed_at     timestamptz,
  note            text
);
alter table public.stripe_event_reprocess_grants enable row level security;
alter table public.stripe_event_reprocess_grants force row level security;
revoke all on public.stripe_event_reprocess_grants from public, anon, authenticated;
-- No client policy on purpose: service_role only, through the RPC below.

create or replace function public.admin_grant_stripe_event_reprocess(
  p_event_id text, p_note text default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if p_event_id is null or p_event_id !~ '^evt_[A-Za-z0-9]+$' then
    raise exception 'invalid stripe event id';
  end if;
  if not exists (select 1 from public.payment_event_ledger where stripe_event_id = p_event_id) then
    raise exception 'event % was never recorded; nothing to reprocess — resend it from Stripe', p_event_id;
  end if;
  insert into public.stripe_event_reprocess_grants (stripe_event_id, granted_by, note)
  values (p_event_id, auth.uid(), left(coalesce(p_note,''), 300))
  on conflict (stripe_event_id) do update
    set granted_at = now(), consumed_at = null, granted_by = auth.uid(),
        note = excluded.note;
end $$;
revoke all on function public.admin_grant_stripe_event_reprocess(text, text) from public, anon, authenticated;
grant execute on function public.admin_grant_stripe_event_reprocess(text, text) to service_role;

-- The projection function, unchanged EXCEPT the duplicate gate consumes a grant.
-- Body otherwise identical to the live definition (verified byte-equal to
-- supabase/migrations/20260910_001040_ledger_insert_once.sql on 2026-09-14).
create or replace function public.apply_stripe_billing_event(
  p_event_id text, p_event_type text, p_provider_id uuid, p_subscription_id text,
  p_price_id text, p_status text, p_plan text, p_period_start timestamptz,
  p_period_end timestamptz, p_cancel_at_period_end boolean, p_coupon text,
  p_amount_minor bigint, p_currency text, p_payload_sha256 text, p_occurred_at timestamptz)
returns text language plpgsql security definer set search_path to '' as $function$
declare
  v_new_plan text; v_new_status text; v_result text; v_outcome text := 'ignored';
  v_prior_id uuid; v_ledger_event_id text := p_event_id; v_reprocess boolean := false;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_event_id, 0));
  select id into v_prior_id from public.payment_event_ledger
    where stripe_event_id = p_event_id order by occurred_at desc limit 1;
  if v_prior_id is not null then
    -- One-shot bypass: an unconsumed grant for this exact event id.
    update public.stripe_event_reprocess_grants
      set consumed_at = now()
      where stripe_event_id = p_event_id and consumed_at is null;
    if not found then
      return 'duplicate';
    end if;
    v_reprocess := true;
    -- The ledger keys on stripe_event_id, so the corrective row carries a
    -- suffixed id and links back through reverses_entry_id (the column that
    -- exists for exactly this: a later entry that supersedes an earlier one).
    v_ledger_event_id := p_event_id || '#reprocess:' || to_char(now() at time zone 'utc', 'YYYYMMDDHH24MISS');
  end if;

  <<project>>
  begin
    if p_subscription_id is not null then
      insert into public.billing_subscriptions
        (provider_id, stripe_subscription_id, stripe_price_id, status,
         current_period_start, current_period_end, cancel_at_period_end, coupon, updated_at)
      values
        (p_provider_id, p_subscription_id, coalesce(p_price_id,''), coalesce(p_status,'unknown'),
         p_period_start, p_period_end, coalesce(p_cancel_at_period_end,false),
         p_coupon, coalesce(p_occurred_at, now()))
      on conflict (stripe_subscription_id) do update
        set stripe_price_id=excluded.stripe_price_id, status=excluded.status,
            current_period_start=excluded.current_period_start,
            current_period_end=excluded.current_period_end,
            cancel_at_period_end=excluded.cancel_at_period_end,
            coupon=excluded.coupon, updated_at=excluded.updated_at
        where public.billing_subscriptions.updated_at <= excluded.updated_at
           or v_reprocess;  -- a granted reprocess may legitimately re-apply an older snapshot
      if not found then v_result := 'stale'; exit project; end if;
    end if;

    if p_status in ('active','trialing') then
      if p_plan in ('pro','enterprise') then
        v_new_plan := p_plan; v_new_status := p_status;
      else
        v_result := 'ignored_bad_plan:' || coalesce(p_plan,'null'); exit project;
      end if;
    elsif p_status in ('past_due','unpaid') then
      v_new_plan := null; v_new_status := 'past_due';
    elsif p_status = 'incomplete' then
      v_new_plan := null; v_new_status := 'incomplete';
    elsif p_status in ('canceled','incomplete_expired') then
      v_new_plan := 'free'; v_new_status := 'canceled';
    else
      v_result := 'ignored_unknown_status:' || coalesce(p_status,'null'); exit project;
    end if;

    update public.providers
      set plan = coalesce(v_new_plan, plan),
          plan_status = v_new_status,
          plan_period_end = p_period_end
      where id = p_provider_id;
    if not found then v_result := 'provider_not_found'; exit project; end if;

    v_outcome := 'applied';
    v_result := 'applied:' || coalesce(v_new_plan,'keep') || '/' || v_new_status;
  end;

  insert into public.payment_event_ledger
    (stripe_event_id, event_type, booking_id, stripe_object_id,
     amount_minor, currency, payload_sha256, outcome, occurred_at, reverses_entry_id)
  values
    (v_ledger_event_id, p_event_type, null, p_subscription_id,
     p_amount_minor, p_currency, p_payload_sha256, v_outcome, p_occurred_at,
     case when v_reprocess then v_prior_id end);
  return case when v_reprocess then 'reprocessed:' || v_result else v_result end;
end $function$;
revoke all on function public.apply_stripe_billing_event(text,text,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,bigint,text,text,timestamptz) from public, anon, authenticated;
grant execute on function public.apply_stripe_billing_event(text,text,uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,bigint,text,text,timestamptz) to service_role;

commit;

-- NOTE FOR REVIEW: the handler must learn the new 'reprocessed:applied:…' prefix
-- (bucket APPLIED). It is intentionally NOT in the handler PR so the two changes
-- can be reviewed and applied independently; until this draft is applied, the
-- prefix can never occur.
