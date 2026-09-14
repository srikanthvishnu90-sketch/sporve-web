-- 20260909234533 — connector OAuth state + Vault-backed secret handling
-- (spec: 20260909_001038_connector_oauth_and_vault).
-- [CRITICAL-PATH] Reconstructed 2026-09-14 from the live catalog
-- (project tseszaprvtvqrkfpditu); the migration is applied in the DB but was
-- missing from the repo. OAuth refresh tokens live in Supabase Vault, never in
-- org_connectors; only service_role may store/read/forget them, and deleting a
-- connector row drops its Vault secret via a BEFORE DELETE trigger.

-- Short-lived CSRF/PKCE state for the OAuth handshake (service-role only).
create table if not exists public.connector_oauth_state (
  state       text primary key,
  provider_id uuid not null references public.providers(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  kind        public.connector_kind not null,
  redirect_to text,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '10 minutes')
);

create index if not exists connector_oauth_state_expiry_idx
  on public.connector_oauth_state using btree (expires_at);

alter table public.connector_oauth_state enable row level security;
alter table public.connector_oauth_state force row level security;
-- No policy: the table is reachable only through service_role / SECURITY DEFINER.
revoke all on public.connector_oauth_state from anon, authenticated;

-- Store (or rotate) a connector's OAuth secret in Vault, returning its id.
create or replace function public.connector_store_secret(p_connector uuid, p_secret text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public','vault','pg_temp'
as $function$
declare v_old uuid; v_new uuid;
begin
  if p_secret is null or length(p_secret) = 0 then
    raise exception 'refusing to store an empty connector secret';
  end if;

  select vault_secret_id into v_old
    from public.org_connectors where id = p_connector for update;
  if not found then
    raise exception 'no such connector %', p_connector;
  end if;

  -- Drop the superseded secret FIRST: vault.secrets.name is unique and the
  -- name derives from the connector id, so create-before-delete would collide
  -- on every reconnect. One transaction, so a failed create rolls the delete
  -- back with it and the old token survives.
  if v_old is not null then
    delete from vault.secrets where id = v_old;
  end if;

  v_new := vault.create_secret(p_secret, 'connector:' || p_connector::text,
                               'OAuth refresh token for org_connectors row ' || p_connector::text);
  update public.org_connectors set vault_secret_id = v_new, updated_at = now()
   where id = p_connector;
  return v_new;
end $function$;

-- Read the decrypted secret for a connected connector (null otherwise).
create or replace function public.connector_read_secret(p_connector uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public','vault','pg_temp'
as $function$
declare v_id uuid; v_secret text;
begin
  select vault_secret_id into v_id from public.org_connectors
   where id = p_connector and status = 'connected';
  if v_id is null then return null; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where id = v_id;
  return v_secret;
end $function$;

-- Forget a connector's secret and mark it disconnected.
create or replace function public.connector_forget_secret(p_connector uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public','vault','pg_temp'
as $function$
declare v_id uuid;
begin
  select vault_secret_id into v_id from public.org_connectors
   where id = p_connector for update;
  if v_id is not null then
    delete from vault.secrets where id = v_id;
  end if;
  update public.org_connectors
     set vault_secret_id = null, status = 'disconnected',
         revoked_at = now(), updated_at = now()
   where id = p_connector;
end $function$;

-- Atomically claim (and sweep expired) OAuth handshake state.
create or replace function public.connector_claim_oauth_state(p_state text)
 returns table(provider_id uuid, user_id uuid, kind public.connector_kind, redirect_to text)
 language sql
 security definer
 set search_path to 'public','pg_temp'
as $function$
  with swept as (
    delete from public.connector_oauth_state
     where expires_at <= now()
    returning 1
  )
  delete from public.connector_oauth_state s
   where s.state = p_state
     and s.expires_at > now()
  returning s.provider_id, s.user_id, s.kind, s.redirect_to;
$function$;

-- Deleting a connector row drops its Vault secret in the same transaction.
create or replace function public.connector_drop_secret_tg()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public','vault','pg_temp'
as $function$
begin
  if old.vault_secret_id is not null then
    delete from vault.secrets where id = old.vault_secret_id;
  end if;
  return old;
end $function$;

drop trigger if exists org_connectors_drop_secret on public.org_connectors;
create trigger org_connectors_drop_secret
  before delete on public.org_connectors
  for each row execute function public.connector_drop_secret_tg();

-- These RPCs are service-role only; no client role may call them directly.
revoke all on function public.connector_store_secret(uuid,text)   from public, anon, authenticated;
revoke all on function public.connector_read_secret(uuid)         from public, anon, authenticated;
revoke all on function public.connector_forget_secret(uuid)       from public, anon, authenticated;
revoke all on function public.connector_claim_oauth_state(text)   from public, anon, authenticated;
grant execute on function public.connector_store_secret(uuid,text) to service_role;
grant execute on function public.connector_read_secret(uuid)       to service_role;
grant execute on function public.connector_forget_secret(uuid)     to service_role;
grant execute on function public.connector_claim_oauth_state(text) to service_role;
