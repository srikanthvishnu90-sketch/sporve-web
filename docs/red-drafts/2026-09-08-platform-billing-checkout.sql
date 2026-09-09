-- [CRITICAL-PATH] REVIEW DRAFT ONLY. Requires catalog + platform billing drafts.
-- Preconditions: verified platform price mappings; separate key/mode; owner auth
-- at the edge; no unexpired legacy Checkout sessions at cutover.
-- Inverse: disable new Checkout; preserve pending sessions and receipts, expire
-- sessions in Stripe before retiring reservations. Never erase billing history.
begin;
create table public.platform_billing_checkout_reservations (
  request_id uuid primary key,
  provider_id uuid not null references public.providers(id) on delete restrict,
  livemode boolean not null,
  stripe_customer_id text not null,
  stripe_price_id text not null,
  stripe_checkout_session_id text unique check (stripe_checkout_session_id ~ '^cs_[A-Za-z0-9_]+$'),
  stripe_subscription_id text check (stripe_subscription_id ~ '^sub_[A-Za-z0-9]+$'),
  success_url text not null,
  cancel_url text not null,
  coupon_id text,
  state text not null default 'pending' check(state in ('pending','completed','expired')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  foreign key(provider_id,livemode) references public.platform_billing_provider_bindings(provider_id,livemode),
  foreign key(livemode,stripe_customer_id) references public.platform_billing_customers(livemode,stripe_customer_id),
  foreign key(livemode,stripe_price_id) references public.platform_billing_prices(livemode,stripe_price_id)
);
create unique index platform_billing_checkout_one_pending on public.platform_billing_checkout_reservations(provider_id,livemode) where state='pending';
alter table public.platform_billing_checkout_reservations enable row level security;
revoke all on public.platform_billing_checkout_reservations from public,anon,authenticated,service_role;
grant select on public.platform_billing_checkout_reservations to service_role;

create function public.register_platform_billing_customer(p_provider_id uuid,p_customer_id text,p_livemode boolean)
returns text language plpgsql security definer set search_path='' as $$
declare v_binding public.platform_billing_provider_bindings%rowtype; v_customer text;
begin
  if p_livemode is null or p_customer_id is null or p_customer_id !~ '^cus_[A-Za-z0-9]+$' then
    raise exception 'Invalid billing customer' using errcode='22023';
  end if;
  perform 1 from public.providers where id=p_provider_id for update;
  if not found then raise exception 'Unknown provider' using errcode='22023'; end if;
  select * into v_binding from public.platform_billing_provider_bindings where provider_id=p_provider_id for update;
  if found and v_binding.livemode<>p_livemode then raise exception 'Billing mode mismatch' using errcode='22023'; end if;
  if not found then
    insert into public.platform_billing_provider_bindings(provider_id,livemode,verified_at,verified_by)
      values(p_provider_id,p_livemode,now(),'billing-checkout:stripe-customer-retrieve');
    if not found then raise exception 'Missing mode binding' using errcode='55000'; end if;
  end if;
  select stripe_customer_id into v_customer from public.platform_billing_customers where provider_id=p_provider_id and livemode=p_livemode;
  if found then
    if v_customer<>p_customer_id then raise exception 'Existing billing customer differs' using errcode='22023'; end if;
    return v_customer;
  end if;
  insert into public.platform_billing_customers(provider_id,livemode,stripe_customer_id,verified_at,verified_by)
    values(p_provider_id,p_livemode,p_customer_id,now(),'billing-checkout:stripe-customer-retrieve') returning stripe_customer_id into v_customer;
  if v_customer is distinct from p_customer_id then raise exception 'Missing customer receipt' using errcode='55000'; end if;
  return v_customer;
end; $$;

create function public.reserve_platform_billing_checkout(p_request jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_provider uuid; v_mode boolean; v_res public.platform_billing_checkout_reservations%rowtype;
  v_auth public.platform_billing_subscription_authorizations%rowtype; v_status text;
begin
  if jsonb_typeof(p_request) is distinct from 'object' or jsonb_typeof(p_request->'livemode') is distinct from 'boolean' then
    raise exception 'Invalid checkout reservation' using errcode='22023'; end if;
  v_provider:=(p_request->>'providerId')::uuid; v_mode:=(p_request->>'livemode')::boolean;
  perform 1 from public.providers where id=v_provider for update;
  if not found then raise exception 'Unknown provider' using errcode='22023'; end if;
  perform 1 from public.platform_billing_provider_bindings where provider_id=v_provider and livemode=v_mode for update;
  if not found then raise exception 'Missing billing binding' using errcode='22023'; end if;
  perform 1 from public.platform_billing_customers where provider_id=v_provider and livemode=v_mode and stripe_customer_id=p_request->>'customerId';
  if not found then raise exception 'Customer identity mismatch' using errcode='22023'; end if;
  perform 1 from public.platform_billing_prices p join public.plan_entitlements e on e.plan=p.plan_key
    where p.livemode=v_mode and p.stripe_price_id=p_request->>'priceId' and p.active and e.purchasable;
  if not found then raise exception 'Price unavailable' using errcode='22023'; end if;
  select * into v_res from public.platform_billing_checkout_reservations where request_id=(p_request->>'requestId')::uuid;
  if found then
    if v_res.provider_id<>v_provider or v_res.livemode<>v_mode or v_res.stripe_customer_id is distinct from p_request->>'customerId'
      or v_res.stripe_price_id is distinct from p_request->>'priceId' or v_res.success_url is distinct from p_request->>'successUrl'
      or v_res.cancel_url is distinct from p_request->>'cancelUrl' or v_res.coupon_id is distinct from p_request->>'couponId' then
      raise exception 'Checkout request identity mismatch' using errcode='22023'; end if;
    return to_jsonb(v_res);
  end if;
  if exists(select 1 from public.platform_billing_checkout_reservations where provider_id=v_provider and livemode=v_mode and state='pending') then
    raise exception 'A checkout is already pending; resume it before starting another' using errcode='PT409'; end if;
  select * into v_auth from public.platform_billing_subscription_authorizations where provider_id=v_provider and livemode=v_mode;
  if found then
    select stripe_status into v_status from public.platform_billing_subscriptions where livemode=v_mode and stripe_subscription_id=v_auth.stripe_subscription_id;
    if v_status is null or v_status not in ('canceled','incomplete_expired') then
      raise exception 'Manage the existing subscription in Billing' using errcode='PT409'; end if;
  end if;
  insert into public.platform_billing_checkout_reservations(request_id,provider_id,livemode,stripe_customer_id,stripe_price_id,success_url,cancel_url,coupon_id)
    values((p_request->>'requestId')::uuid,v_provider,v_mode,p_request->>'customerId',p_request->>'priceId',p_request->>'successUrl',p_request->>'cancelUrl',p_request->>'couponId')
    returning * into v_res;
  if v_res.request_id is null then raise exception 'Missing checkout reservation' using errcode='55000'; end if;
  return to_jsonb(v_res);
end; $$;

create function public.record_platform_billing_checkout(p_request_id uuid,p_session_id text,p_livemode boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_res public.platform_billing_checkout_reservations%rowtype;
begin
  if p_session_id is null or p_session_id !~ '^cs_[A-Za-z0-9_]+$' or p_livemode is null then
    raise exception 'Invalid checkout session' using errcode='22023'; end if;
  select * into v_res from public.platform_billing_checkout_reservations where request_id=p_request_id and livemode=p_livemode for update;
  if not found then raise exception 'Missing checkout reservation' using errcode='22023'; end if;
  if v_res.stripe_checkout_session_id is not null then
    if v_res.stripe_checkout_session_id<>p_session_id then raise exception 'Checkout identity mismatch' using errcode='22023'; end if;
    return to_jsonb(v_res);
  end if;
  if v_res.state<>'pending' then raise exception 'Checkout is not pending' using errcode='22023'; end if;
  update public.platform_billing_checkout_reservations set stripe_checkout_session_id=p_session_id
    where request_id=p_request_id returning * into v_res;
  if not found then raise exception 'Missing checkout receipt' using errcode='55000'; end if;
  return to_jsonb(v_res);
end; $$;

-- Called only after the signed event's session is fetched from Stripe and
-- confirmed complete, with matching customer, subscription, price and mode.
create function public.bind_platform_billing_checkout(p_livemode boolean,p_checkout_session_id text,p_customer_id text,p_subscription_id text,p_price_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_res public.platform_billing_checkout_reservations%rowtype; v_provider uuid;
  v_auth public.platform_billing_subscription_authorizations%rowtype; v_status text; v_revision bigint;
begin
  if p_livemode is null or p_subscription_id is null or p_subscription_id !~ '^sub_[A-Za-z0-9]+$' then
    raise exception 'Invalid subscription identity' using errcode='22023'; end if;
  select provider_id into v_provider from public.platform_billing_checkout_reservations where livemode=p_livemode and stripe_checkout_session_id=p_checkout_session_id;
  if not found then raise exception 'Checkout was not reserved' using errcode='22023'; end if;
  perform 1 from public.providers where id=v_provider for update;
  perform 1 from public.platform_billing_provider_bindings where provider_id=v_provider and livemode=p_livemode for update;
  if not found then raise exception 'Missing provider binding' using errcode='55000'; end if;
  select * into strict v_res from public.platform_billing_checkout_reservations where livemode=p_livemode and stripe_checkout_session_id=p_checkout_session_id for update;
  if v_res.stripe_customer_id is distinct from p_customer_id or v_res.stripe_price_id is distinct from p_price_id then
    raise exception 'Checkout identity mismatch' using errcode='22023'; end if;
  if v_res.state='completed' then
    if v_res.stripe_subscription_id is distinct from p_subscription_id then raise exception 'Subscription identity mismatch' using errcode='22023'; end if;
    select projection_revision into strict v_revision from public.platform_billing_provider_bindings where provider_id=v_provider;
    return jsonb_build_object('authorized',true,'outcome','duplicate','provider_id',v_provider,'subscription_id',p_subscription_id,
      'customer_id',p_customer_id,'price_id',p_price_id,'projection_revision',v_revision,'checkout_session_id',p_checkout_session_id);
  end if;
  if v_res.state<>'pending' then raise exception 'Checkout is not pending' using errcode='22023'; end if;
  select * into v_auth from public.platform_billing_subscription_authorizations where provider_id=v_provider and livemode=p_livemode;
  if found and v_auth.stripe_subscription_id<>p_subscription_id then
    select stripe_status into v_status from public.platform_billing_subscriptions where livemode=p_livemode and stripe_subscription_id=v_auth.stripe_subscription_id;
    if v_status is null or v_status not in ('canceled','incomplete_expired') then
      raise exception 'Existing subscription still active' using errcode='22023'; end if;
  end if;
  insert into public.platform_billing_subscription_authorizations(provider_id,livemode,stripe_subscription_id,stripe_customer_id,state,verified_at,verified_by)
    values(v_provider,p_livemode,p_subscription_id,p_customer_id,'pending',now(),'billing-webhook:reserved-checkout')
    on conflict(provider_id,livemode) do update set stripe_subscription_id=excluded.stripe_subscription_id,
      stripe_customer_id=excluded.stripe_customer_id,state='pending',verified_at=excluded.verified_at,verified_by=excluded.verified_by;
  if not found then raise exception 'Missing subscription authorization receipt' using errcode='55000'; end if;
  update public.platform_billing_provider_bindings set projection_revision=projection_revision+1 where provider_id=v_provider returning projection_revision into v_revision;
  if not found then raise exception 'Missing authorization revision' using errcode='55000'; end if;
  update public.platform_billing_checkout_reservations set state='completed',stripe_subscription_id=p_subscription_id,completed_at=now()
    where request_id=v_res.request_id;
  if not found then raise exception 'Missing checkout activation receipt' using errcode='55000'; end if;
  return jsonb_build_object('authorized',true,'outcome','bound','provider_id',v_provider,'subscription_id',p_subscription_id,
    'customer_id',p_customer_id,'price_id',p_price_id,'checkout_session_id',p_checkout_session_id,'projection_revision',v_revision);
end; $$;

-- Only called after Stripe retrieval confirms this exact recorded session is
-- expired. Time elapsed locally is not enough: an already-paid session must
-- never be retired, otherwise two subscriptions could be created.
create function public.retire_platform_billing_checkout(p_request_id uuid,p_session_id text,p_livemode boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_provider uuid; v_res public.platform_billing_checkout_reservations%rowtype;
begin
  select provider_id into v_provider from public.platform_billing_checkout_reservations where request_id=p_request_id;
  if not found then raise exception 'Missing reservation' using errcode='22023'; end if;
  perform 1 from public.providers where id=v_provider for update;
  select * into strict v_res from public.platform_billing_checkout_reservations where request_id=p_request_id for update;
  if v_res.livemode is distinct from p_livemode or v_res.stripe_checkout_session_id is distinct from p_session_id or p_session_id is null then
    raise exception 'Checkout identity mismatch' using errcode='22023'; end if;
  if v_res.state='completed' then raise exception 'Completed checkout cannot expire' using errcode='22023'; end if;
  update public.platform_billing_checkout_reservations set state='expired' where request_id=p_request_id returning * into v_res;
  if not found then raise exception 'Missing expiry receipt' using errcode='55000'; end if;
  return to_jsonb(v_res);
end; $$;

revoke all on function public.register_platform_billing_customer(uuid,text,boolean),public.reserve_platform_billing_checkout(jsonb),
  public.record_platform_billing_checkout(uuid,text,boolean),public.bind_platform_billing_checkout(boolean,text,text,text,text),public.retire_platform_billing_checkout(uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.register_platform_billing_customer(uuid,text,boolean),public.reserve_platform_billing_checkout(jsonb),
  public.record_platform_billing_checkout(uuid,text,boolean),public.bind_platform_billing_checkout(boolean,text,text,text,text),public.retire_platform_billing_checkout(uuid,text,boolean) to service_role;
commit;
