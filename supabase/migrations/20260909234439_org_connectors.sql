-- 20260909234439 — org connectors foundation (spec: 20260909_001037_org_connectors).
-- Reconstructed 2026-09-14 from the live catalog (project tseszaprvtvqrkfpditu):
-- the applied migration is present in the DB but was missing from the repo.
-- Introduces the connector kind/status/write-mode enums, the org_connectors
-- registry (one live connector per provider+kind), the connector_sync_state
-- bookkeeping table, and the source_connector_id provenance columns on the two
-- import surfaces. RLS restricts every row to the owning provider.

-- Enums (guarded so a re-run is a no-op).
do $$ begin
  create type public.connector_kind as enum (
    'stripe','website','file_import','gmail','google_calendar','microsoft365',
    'sms','google_sheets','google_drive','quickbooks','google_business_profile');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.connector_write_mode as enum ('none','draft','apply');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.connector_status as enum (
    'connected','revoked','expired','error','disconnected');
exception when duplicate_object then null; end $$;

-- Registry of a provider's connected external systems.
create table if not exists public.org_connectors (
  id               uuid primary key default gen_random_uuid(),
  provider_id      uuid not null references public.providers(id) on delete cascade,
  kind             public.connector_kind not null,
  status           public.connector_status not null default 'connected',
  write_mode       public.connector_write_mode not null default 'none',
  external_account text,
  scopes           text[] not null default '{}'::text[],
  vault_secret_id  uuid,
  connected_by     uuid references auth.users(id) on delete set null,
  connected_at     timestamptz not null default now(),
  revoked_at       timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- One live connector per provider+kind.
alter table public.org_connectors drop constraint if exists org_connectors_one_live_per_kind;
alter table public.org_connectors add constraint org_connectors_one_live_per_kind
  unique (provider_id, kind);

-- Send-capable kinds may never exceed draft; other kinds are strictly read-only.
alter table public.org_connectors drop constraint if exists org_connectors_no_send;
alter table public.org_connectors add constraint org_connectors_no_send check (
  case
    when kind = any (array['gmail'::public.connector_kind,'microsoft365'::public.connector_kind,'sms'::public.connector_kind])
      then write_mode = any (array['none'::public.connector_write_mode,'draft'::public.connector_write_mode])
    else true
  end);

alter table public.org_connectors drop constraint if exists org_connectors_readonly_kinds;
alter table public.org_connectors add constraint org_connectors_readonly_kinds check (
  case
    when kind = any (array['website'::public.connector_kind,'file_import'::public.connector_kind,'google_sheets'::public.connector_kind,'google_drive'::public.connector_kind,'quickbooks'::public.connector_kind])
      then write_mode = 'none'::public.connector_write_mode
    else true
  end);

create index if not exists org_connectors_provider_idx
  on public.org_connectors using btree (provider_id, status);

-- Per-connector sync bookkeeping (cursor, last success/attempt/error).
create table if not exists public.connector_sync_state (
  connector_id    uuid primary key references public.org_connectors(id) on delete cascade,
  provider_id     uuid not null references public.providers(id) on delete cascade,
  cursor          text,
  last_success_at timestamptz,
  last_attempt_at timestamptz,
  last_error      text,
  last_error_at   timestamptz,
  items_seen      bigint not null default 0,
  updated_at      timestamptz not null default now()
);

create index if not exists connector_sync_state_provider_idx
  on public.connector_sync_state using btree (provider_id);

-- Provenance: which connector imported a row (null for manual entry).
alter table public.team_athletes
  add column if not exists source_connector_id uuid references public.org_connectors(id) on delete set null;
alter table public.import_batches
  add column if not exists source_connector_id uuid references public.org_connectors(id) on delete set null;

create index if not exists team_athletes_source_connector_idx
  on public.team_athletes using btree (source_connector_id)
  where source_connector_id is not null;

-- RLS: a provider owner sees and writes only their own connector rows.
alter table public.org_connectors      enable row level security;
alter table public.connector_sync_state enable row level security;
alter table public.org_connectors      force row level security;
alter table public.connector_sync_state force row level security;

drop policy if exists org_connectors_owner_all on public.org_connectors;
create policy org_connectors_owner_all on public.org_connectors
  for all to authenticated
  using (exists (select 1 from public.providers p
                 where p.id = org_connectors.provider_id and p.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.providers p
                 where p.id = org_connectors.provider_id and p.owner_id = (select auth.uid())));

drop policy if exists connector_sync_state_owner_read on public.connector_sync_state;
create policy connector_sync_state_owner_read on public.connector_sync_state
  for select to authenticated
  using (exists (select 1 from public.providers p
                 where p.id = connector_sync_state.provider_id and p.owner_id = (select auth.uid())));

revoke all on public.org_connectors       from anon;
revoke all on public.connector_sync_state from anon;
