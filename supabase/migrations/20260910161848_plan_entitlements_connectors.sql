-- 20260910161848 — plan entitlements catalog, including per-plan connectors
-- (spec: 20260910_001039_plan_entitlements_connectors).
-- Reconstructed 2026-09-14 from the live catalog (project tseszaprvtvqrkfpditu);
-- the migration is applied in the DB but was missing from the repo. One row per
-- billing plan describing what it unlocks; the connectors[] column gates which
-- connector kinds each plan may connect. Publicly readable so the pricing/signup
-- surfaces can render entitlements; writes are owner/service-role only via RLS.

create table if not exists public.plan_entitlements (
  plan             text primary key,
  ai_monthly_quota integer,
  seat_limit       integer,
  workspace_enabled boolean not null default false,
  purchasable      boolean not null default false,
  price_usd_month  numeric(6,2),
  updated_at       timestamptz not null default now(),
  connectors       text[] not null default '{}'::text[]
);

alter table public.plan_entitlements drop constraint if exists plan_entitlements_plan_check;
alter table public.plan_entitlements add constraint plan_entitlements_plan_check
  check (plan = any (array['free'::text,'pro'::text,'enterprise'::text]));

-- Seed the three plans (idempotent upsert to the live values).
insert into public.plan_entitlements
  (plan, ai_monthly_quota, seat_limit, workspace_enabled, purchasable, price_usd_month, connectors)
values
  ('free',        3,    1,    false, true,  0.00,
     array['website','file_import','stripe']),
  ('pro',         null, 3,    false, true,  34.99,
     array['website','file_import','stripe','gmail','google_calendar','sms']),
  ('enterprise',  null, null, false, false, 149.00,
     array['website','file_import','stripe','gmail','google_calendar','sms','microsoft365','google_sheets','google_drive','quickbooks','google_business_profile'])
on conflict (plan) do update set
  ai_monthly_quota  = excluded.ai_monthly_quota,
  seat_limit        = excluded.seat_limit,
  workspace_enabled = excluded.workspace_enabled,
  purchasable       = excluded.purchasable,
  price_usd_month   = excluded.price_usd_month,
  connectors        = excluded.connectors,
  updated_at        = now();

alter table public.plan_entitlements enable row level security;

drop policy if exists plan_entitlements_public_read on public.plan_entitlements;
create policy plan_entitlements_public_read on public.plan_entitlements
  for select to anon, authenticated
  using (true);
