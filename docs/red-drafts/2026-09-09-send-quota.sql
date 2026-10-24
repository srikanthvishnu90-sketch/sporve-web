-- [CRITICAL-PATH] REVIEW DRAFT — NOT APPLIED.
-- Prerequisite: reviewed plan-entitlements catalog and effective-plan resolver.
-- Deployment gate: EVERY sender must reserve here before delivering; legacy
-- sent-row accounting alone cannot serialize a legacy sender. No launch claim
-- until lifecycle-approve/process and parent-update-send use this pool.
-- No money, export or read path calls this pool. A downgrade deletes nothing.
begin;

create table public.message_send_quota_claims (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  source_kind text not null check (source_kind in ('outbound','parent_update')),
  source_id uuid not null,
  quota_month date not null,
  state text not null check (state in ('reserved','accepted')),
  reserved_at timestamptz not null,
  accepted_at timestamptz,
  delivery_receipt_id uuid,
  unique(source_kind,source_id),
  check (quota_month=date_trunc('month',reserved_at at time zone 'UTC')::date),
  check ((state='reserved' and accepted_at is null and delivery_receipt_id is null)
      or (state='accepted' and accepted_at is not null and delivery_receipt_id is not null))
);
create index message_send_quota_month on public.message_send_quota_claims(provider_id,quota_month);
alter table public.message_send_quota_claims enable row level security;
revoke all on public.message_send_quota_claims from public,anon,authenticated,service_role;
grant select on public.message_send_quota_claims to service_role;

create table public.message_send_quota_events (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null,
  provider_id uuid not null,
  event text not null check (event in ('reserved','accepted')),
  delivery_receipt_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  unique(claim_id,event)
);
alter table public.message_send_quota_events enable row level security;
revoke all on public.message_send_quota_events from public,anon,authenticated,service_role;
grant select on public.message_send_quota_events to service_role;
create function public.guard_send_quota_audit()
returns trigger language plpgsql set search_path='' as $$
begin raise exception using errcode='55000',message='Send quota audit is append-only'; end;
$$;
revoke all on function public.guard_send_quota_audit() from public,anon,authenticated,service_role;
create trigger message_send_quota_events_immutable before update or delete on public.message_send_quota_events
for each row execute function public.guard_send_quota_audit();

-- Internal primitives: no browser/service role can call them directly. A
-- reviewed owner-authorizing delivery RPC owns the source row lock, verifies
-- approval and tenant/family identity, and invokes them in that transaction.
create function public.reserve_message_send_quota_internal(p_provider uuid,p_kind text,p_source uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  v_claim public.message_send_quota_claims%rowtype;
  v_plan text; v_order integer; v_limit integer; v_count bigint; v_upgrade text;
  v_now timestamptz; v_month date; v_event uuid;
begin
  if p_provider is null or p_source is null or p_kind is null or p_kind not in ('outbound','parent_update') then
    raise exception using errcode='PT503',message='Invalid send quota context';
  end if;
  perform 1 from public.providers where id=p_provider for share;
  if not found then raise exception using errcode='PT503',message='Send organization unavailable'; end if;
  perform 1 from public.provider_entitlement_assignments where provider_id=p_provider for share;
  perform pg_advisory_xact_lock(hashtextextended(p_provider::text,41204));
  v_now:=clock_timestamp(); v_month:=date_trunc('month',v_now at time zone 'UTC')::date;
  select * into v_claim from public.message_send_quota_claims where source_kind=p_kind and source_id=p_source for update;
  if found then
    if v_claim.provider_id<>p_provider then raise exception using errcode='42501',message='Send quota identity mismatch'; end if;
    -- A durable acceptance is historical evidence, not a new send. Never
    -- revoke or rewrite its receipt on cancellation, downgrade or month rollover.
    if v_claim.state='accepted' then return v_claim.id; end if;
    -- The current pool cannot prove whether an old reserved email was accepted
    -- externally. Do not silently transfer or release that allowance or enable
    -- a new dispatch beyond the provider's idempotency retention. A reviewed
    -- delivery/reconciliation protocol must resolve it first; keep the row.
    if v_claim.quota_month<>v_month then
      raise exception using errcode='PT409',message='Prior-month send reservation requires reconciliation';
    end if;
  end if;
  select e.public_slug,e.sort_order,e.send_quota_month into strict v_plan,v_order,v_limit
    from public.plan_entitlements e
    where e.plan=(public.resolve_provider_entitlements_internal(p_provider)->>'effective_plan') for share;
  -- Reservations count, including ambiguous email dispatches. Never release
  -- an uncertain provider acceptance or reuse its allowance on a timeout.
  select (select count(*) from public.message_send_quota_claims where provider_id=p_provider and quota_month=v_month)
    + (select count(*) from public.parent_updates u where u.provider_id=p_provider
        and u.sent_at>=(v_month::timestamp at time zone 'UTC')
        and u.sent_at<((v_month+interval '1 month') at time zone 'UTC')
        and not exists(select 1 from public.message_send_quota_claims q where q.source_kind='parent_update' and q.source_id=u.id))
    + (select count(*) from public.outbound_messages o where o.provider_id=p_provider
        and o.sent_at>=(v_month::timestamp at time zone 'UTC')
        and o.sent_at<((v_month+interval '1 month') at time zone 'UTC')
        and not exists(select 1 from public.message_send_quota_claims q where q.source_kind='outbound' and q.source_id=o.id))
    into v_count;
  -- Pending reservations are included in v_count already. Recheck the current
  -- entitlement without counting this same logical message a second time.
  -- This closes a downgrade/data-change bypass in the former early return.
  if v_limit<>-1 and v_count+(case when v_claim.id is null then 1 else 0 end)>v_limit then
    select e.public_slug into v_upgrade from public.plan_entitlements e
      where e.purchasable and e.sort_order>v_order and (e.send_quota_month=-1 or e.send_quota_month>v_count)
      order by e.sort_order limit 1;
    raise exception using errcode='PT402',message='Send quota reached',detail=jsonb_build_object(
      'reason','send_quota_month','current_plan',v_plan,'upgrade_to',v_upgrade,'limit',v_limit,'current',v_count)::text;
  end if;
  if v_claim.id is not null then return v_claim.id; end if;
  insert into public.message_send_quota_claims(provider_id,source_kind,source_id,quota_month,state,reserved_at)
    values(p_provider,p_kind,p_source,v_month,'reserved',v_now) returning * into v_claim;
  if v_claim.id is null then raise exception using errcode='PT503',message='Send quota reservation did not persist'; end if;
  insert into public.message_send_quota_events(claim_id,provider_id,event) values(v_claim.id,p_provider,'reserved') returning id into v_event;
  if v_event is null then raise exception using errcode='PT503',message='Send quota reservation audit missing'; end if;
  return v_claim.id;
end;
$$;
revoke all on function public.reserve_message_send_quota_internal(uuid,text,uuid) from public,anon,authenticated,service_role;

create function public.accept_message_send_quota_internal(p_claim uuid,p_provider uuid,p_receipt uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_claim public.message_send_quota_claims%rowtype; v_rows integer; v_event uuid;
begin
  if p_receipt is null then raise exception using errcode='PT503',message='Delivery receipt required'; end if;
  select * into v_claim from public.message_send_quota_claims where id=p_claim and provider_id=p_provider for update;
  if not found then raise exception using errcode='PT503',message='Send quota claim missing'; end if;
  if v_claim.state='accepted' then
    if v_claim.delivery_receipt_id<>p_receipt then raise exception using errcode='PT503',message='Conflicting delivery receipt'; end if;
    return;
  end if;
  update public.message_send_quota_claims set state='accepted',accepted_at=clock_timestamp(),delivery_receipt_id=p_receipt
    where id=p_claim and provider_id=p_provider and state='reserved';
  get diagnostics v_rows=row_count;
  if v_rows<>1 or not exists(select 1 from public.message_send_quota_claims
    where id=p_claim and provider_id=p_provider and state='accepted' and delivery_receipt_id=p_receipt) then
    raise exception using errcode='PT503',message='Send quota acceptance did not persist';
  end if;
  insert into public.message_send_quota_events(claim_id,provider_id,event,delivery_receipt_id)
    values(p_claim,p_provider,'accepted',p_receipt) returning id into v_event;
  if v_event is null then raise exception using errcode='PT503',message='Send quota acceptance audit missing'; end if;
end;
$$;
revoke all on function public.accept_message_send_quota_internal(uuid,uuid,uuid) from public,anon,authenticated,service_role;
commit;
