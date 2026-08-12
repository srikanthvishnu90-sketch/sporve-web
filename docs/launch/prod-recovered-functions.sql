-- Recovered from production tseszaprvtvqrkfpditu on 2026-08-11 via
-- pg_get_functiondef(). These four functions exist in the live database and
-- their source was in NO migration file in either repo.
--
-- claim_provider_role and claim_organization_role were flagged CRITICAL-PATH
-- because they are SECURITY DEFINER privilege-escalation RPCs whose safety
-- property existed only as a comment in Dart:
--
--   // The RPC can only promote the caller's OWN account, so a failure never
--   // escalates anyone and never blocks routing.
--
-- That comment is now VERIFIED against the real source. See the analysis at
-- the bottom of this file.
--
-- DO NOT re-author these from memory. This file is the recovered original.
-- It belongs in the repo that owns supabase/migrations once Phase 0.1 decides
-- which repo that is.

-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.claim_provider_role()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'authentication required'; end if;

  perform set_config('sporve.role_claim', 'on', true);

  update public.profiles
     set role = 'provider'
   where id = v_uid and role = 'searcher';

  insert into public.providers (owner_id, business_name)
  values (v_uid, coalesce(
    (select nullif(trim(concat_ws(' ', first_name, last_name)),'')
       from public.profiles where id = v_uid), 'My Academy'))
  on conflict (owner_id) do nothing;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.claim_organization_role()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'authentication required'; end if;
  update public.providers
     set provider_type = 'organization'
   where owner_id = v_uid and provider_type = 'solo';
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.prevent_profile_role_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null then return new;
  end if;
  if current_setting('sporve.role_claim', true) = 'on'
     and old.role = 'searcher' and new.role = 'provider' then
    return new;
  end if;
  if new.role is distinct from old.role then
    raise exception 'profile role cannot be changed by the client';
  end if;
  return new;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  full_name  text := coalesce(new.raw_user_meta_data ->> 'name', '');
  first_tok  text := split_part(full_name, ' ', 1);
  rest_tok   text := btrim(substr(full_name, length(split_part(full_name, ' ', 1)) + 1));
  the_role   text := case
                       when (new.raw_user_meta_data ->> 'role') in ('searcher', 'provider')
                         then new.raw_user_meta_data ->> 'role'
                       else 'searcher'
                     end;
begin
  insert into public.profiles (id, role, first_name, last_name, email, phone_number)
  values (
    new.id, the_role,
    coalesce(nullif(first_tok, ''), split_part(coalesce(new.email, 'member'), '@', 1), 'Member'),
    nullif(rest_tok, ''), new.email,
    nullif(new.raw_user_meta_data ->> 'phone', '')
  )
  on conflict (id) do nothing;

  if the_role = 'provider' then
    insert into public.providers (owner_id, business_name)
    values (new.id, coalesce(nullif(full_name, ''), 'My Academy'))
    on conflict (owner_id) do nothing;
  end if;

  return new;
exception
  when others then
    raise log 'handle_new_user failed for %: %', new.id, sqlerrm;
    return new;
end;
$function$;


-- ═════════════════════════════════════════════════════════════════════════════
-- SECURITY ANALYSIS — read before changing any of the above
-- ═════════════════════════════════════════════════════════════════════════════
--
-- HOW THE ESCALATION IS GATED (and why it holds)
--
-- prevent_profile_role_change is a BEFORE UPDATE trigger on profiles that
-- raises on any role change. claim_provider_role legally bypasses it with a
-- transaction-local flag:
--
--   set_config('sporve.role_claim', 'on', true)   -- true = local to this txn
--
-- The trigger honours that flag ONLY for the exact transition searcher →
-- provider. Any other transition still raises, flag or no flag.
--
-- The flag cannot be set by a client. set_config lives in pg_catalog, not in
-- the exposed `public` schema, so PostgREST will not route /rpc/set_config.
-- The only writer of that flag is claim_provider_role itself, and that
-- function only ever touches `where id = v_uid`. So the Dart comment is
-- CORRECT: this promotes the caller and nobody else.
--
-- Both functions also set `search_path TO ''`, which closes the classic
-- SECURITY DEFINER attack where a caller shadows a referenced object with one
-- in a schema they control. Every reference inside is schema-qualified. Good.
--
--
-- WHAT IS NOT A VULNERABILITY BUT IS A PRODUCT DECISION
--
-- Becoming a provider requires no approval at all. handle_new_user already
-- honours role='provider' straight from signup metadata, so claim_provider_role
-- grants nothing that signup did not. That is a deliberate open-signup model,
-- not a hole — the real gate is providers.status, which starts 'pending' and
-- keeps the row out of providers_select_public until approved.
--
-- claim_organization_role has NO gate whatsoever. Any provider can self-declare
-- as an organization. Combined with find_affiliatable_account being org-admin
-- gated, that means anyone can sign up, self-promote to provider, self-promote
-- to organization, become their own org admin, and use the affiliation lookup
-- as an account-existence + first-name oracle for any email they hold.
-- Backlog item 2.3. The fix is to gate the oracle, not this function.
--
--
-- TWO DEFECTS FOUND WHILE READING (new — not in any prior audit)
--
-- D1. handle_new_user swallows every exception and returns new. If the profile
--     insert fails for any reason, the auth.users row is still created and the
--     user has NO profiles row. They can authenticate but every RLS policy
--     keyed on profiles will deny them, and they cannot self-repair. There is
--     no reconciliation job. Check prod for orphans:
--
--       select count(*) from auth.users u
--       left join public.profiles p on p.id = u.id
--       where p.id is null;
--
-- D2. prevent_profile_role_change returns new — ALLOWS the change — when
--     auth.uid() is null. That is how migrations and service-role jobs edit
--     roles, so it is intentional. But it means ANY edge function holding the
--     service-role key can silently rewrite any user's role, and 14 functions
--     hold that key. The trigger is not a defence against a compromised
--     function; it only stops the client. Worth stating explicitly because the
--     name suggests broader protection than it provides.
