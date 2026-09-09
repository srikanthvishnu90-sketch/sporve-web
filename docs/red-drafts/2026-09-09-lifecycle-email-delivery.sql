-- [CRITICAL-PATH] REVIEW DRAFT — NOT APPLIED; no external request occurs here.
-- Requires reviewed send-quota/catalog drafts. Deploy ONLY with the email caller.
-- Preconditions: unchanged human approval, current org owner/guardian, no
-- suppression, due row, current quota and an exclusive durable attempt.
-- Receipt: immutable attempt/result plus exact sealed wire body; acceptance,
-- quota and sent projection commit together. No generator can approve here.
-- Inverse: rollback before dispatch; after dispatch reconcile the provider.
-- Never release ambiguous quota or silently authorize a second provider call.
begin;

create table public.outbound_email_dispatches (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null unique,
  provider_id uuid not null,
  actor_id uuid not null,
  approved_at timestamptz not null,
  approved_content jsonb not null,
  guardian_id uuid not null,
  recipient text not null,
  quota_claim_id uuid not null,
  branding_footer boolean not null,
  wire_body text not null,
  wire_sha256 text not null check (wire_sha256 ~ '^[a-f0-9]{64}$'),
  idempotency_key text not null unique,
  created_at timestamptz not null default clock_timestamp(),
  state text not null check (state in ('dispatching','retry_wait','ambiguous','rejected','accepted')),
  active_attempt uuid not null,
  attempt_count integer not null check (attempt_count>0),
  retry_after timestamptz,
  check (encode(sha256(convert_to(wire_body,'UTF8')),'hex')=wire_sha256),
  check ((state='retry_wait')=(retry_after is not null))
);
create index outbound_email_dispatch_org_state on public.outbound_email_dispatches(provider_id,state,created_at);
create table public.outbound_email_attempts (
  id uuid primary key,
  dispatch_id uuid not null references public.outbound_email_dispatches(id),
  ordinal integer not null check (ordinal>0),
  created_at timestamptz not null default clock_timestamp(),
  unique(dispatch_id,ordinal)
);
create table public.outbound_email_results (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null unique references public.outbound_email_attempts(id),
  dispatch_id uuid not null references public.outbound_email_dispatches(id),
  outcome text not null check (outcome in ('accepted','retry_wait','ambiguous','rejected')),
  provider_message_id text,
  retry_after timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  check ((outcome='accepted')=(provider_message_id is not null)),
  check (provider_message_id is null or provider_message_id ~ '^[A-Za-z0-9_-]{1,200}$'),
  check ((outcome='retry_wait')=(retry_after is not null))
);
create unique index outbound_email_one_acceptance on public.outbound_email_results(dispatch_id) where outcome='accepted';
create unique index outbound_email_provider_receipt on public.outbound_email_results(provider_message_id) where provider_message_id is not null;
alter table public.outbound_email_dispatches enable row level security;
alter table public.outbound_email_attempts enable row level security;
alter table public.outbound_email_results enable row level security;
revoke all on public.outbound_email_dispatches,public.outbound_email_attempts,public.outbound_email_results
  from public,anon,authenticated,service_role;
grant select on public.outbound_email_dispatches,public.outbound_email_attempts,public.outbound_email_results to service_role;
create trigger outbound_email_attempts_immutable before update or delete on public.outbound_email_attempts
  for each row execute function public.guard_send_quota_audit();
create trigger outbound_email_results_immutable before update or delete on public.outbound_email_results
  for each row execute function public.guard_send_quota_audit();
create function public.guard_email_dispatch_snapshot() returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='DELETE' or (to_jsonb(new)-array['state','active_attempt','attempt_count','retry_after'])
    is distinct from (to_jsonb(old)-array['state','active_attempt','attempt_count','retry_after']) then
    raise exception using errcode='55000',message='Email dispatch snapshot is immutable';
  end if;
  return new;
end $$;
revoke all on function public.guard_email_dispatch_snapshot() from public,anon,authenticated,service_role;
create trigger outbound_email_snapshot_immutable before update or delete on public.outbound_email_dispatches
  for each row execute function public.guard_email_dispatch_snapshot();

-- Internal receipt builder is not callable by application roles. It returns
-- a byte-stable wire string: the caller must send THIS string, never rerender.
create function public.email_dispatch_receipt_internal(p_dispatch uuid,p_kind text)
returns jsonb language sql security definer set search_path='' as $$
  select jsonb_build_object('kind',p_kind,'dispatch_id',d.id,'message_id',d.message_id,
    'provider_id',d.provider_id,'actor_id',d.actor_id,'approved_at',d.approved_at,
    'approved_content',d.approved_content,'quota_claim_id',d.quota_claim_id,
    'attempt_id',d.active_attempt,'attempt_count',d.attempt_count,'wire_body',d.wire_body,
    'wire_sha256',d.wire_sha256,'idempotency_key',d.idempotency_key,'created_at',d.created_at,
    'branding_footer',d.branding_footer,'state',d.state,'retry_after',d.retry_after,
    'result_id',r.id,'provider_message_id',r.provider_message_id,'accepted_at',
      case when r.outcome='accepted' then r.created_at else null end)
  from public.outbound_email_dispatches d
  left join public.outbound_email_results r on r.attempt_id=d.active_attempt
  where d.id=p_dispatch
$$;
revoke all on function public.email_dispatch_receipt_internal(uuid,text) from public,anon,authenticated,service_role;

create function public.prepare_approved_lifecycle_email(
  p_message uuid,p_provider uuid,p_actor uuid,p_approved_at timestamptz,
  p_expected_content jsonb,p_recipient text,p_from text,p_reply_to text,p_subject text,p_unsubscribe_url text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  m public.outbound_messages%rowtype; d public.outbound_email_dispatches%rowtype;
  g public.guardians%rowtype; v_owner uuid; v_guardian uuid; v_branding boolean;
  v_claim uuid; v_attempt uuid:=gen_random_uuid(); v_wire text; v_text text;
  v_rows integer; v_now timestamptz:=clock_timestamp(); v_receipt jsonb;
  v_key text; v_ordinal integer;
begin
  if p_message is null or p_provider is null or p_actor is null or p_approved_at is null then
    raise exception using errcode='PT409',message='Existing human approval required';
  end if;
  select * into m from public.outbound_messages where id=p_message and provider_id=p_provider for update;
  if not found then raise exception using errcode='42501',message='Message organization mismatch'; end if;
  select owner_id into v_owner from public.providers where id=p_provider for share;
  if v_owner is distinct from p_actor then raise exception using errcode='42501',message='Approving owner required'; end if;
  if m.approved_by is distinct from p_actor or m.approved_at is distinct from p_approved_at
    or m.content is distinct from p_expected_content or jsonb_typeof(m.content) is distinct from 'object'
    or jsonb_typeof(m.content->'body') is distinct from 'string'
    or nullif(btrim(m.content->>'body'),'') is null or length(m.content->>'body')>10000 then
    raise exception using errcode='PT409',message='Approved snapshot changed; human review required';
  end if;
  select * into d from public.outbound_email_dispatches where message_id=p_message for update;
  if found then
    if d.provider_id<>p_provider or d.actor_id<>p_actor or d.approved_at<>p_approved_at
      or d.approved_content is distinct from p_expected_content then
      raise exception using errcode='PT409',message='Dispatch snapshot changed; reconcile before another send';
    end if;
    if d.state='accepted' then
      if not exists(select 1 from public.outbound_email_results r where r.dispatch_id=d.id and r.outcome='accepted'
        and m.status='sent' and m.sent_at=r.created_at and m.provider='resend' and m.provider_message_id=r.provider_message_id) then
        raise exception using errcode='PT503',message='Accepted email projection requires reconciliation';
      end if;
      return public.email_dispatch_receipt_internal(d.id,'already_accepted');
    end if;
    -- A lost prepare response may already have authorized a provider request.
    -- No lease expiry, missing result or repeated cron authorizes another send.
    if d.state<>'retry_wait' then return public.email_dispatch_receipt_internal(d.id,'held'); end if;
    if v_now<d.retry_after then return public.email_dispatch_receipt_internal(d.id,'deferred'); end if;
    if v_now>=d.created_at+interval '23 hours' then
      raise exception using errcode='PT409',message='Email idempotency window requires reconciliation';
    end if;
  end if;
  if m.status<>'approved' or m.sent_at is not null or (m.send_after is not null and m.send_after>v_now) then
    raise exception using errcode='PT409',message='Approved email is not due or requires reconciliation';
  end if;
  begin v_guardian:=(m.content->>'guardian_id')::uuid;
  exception when invalid_text_representation then raise exception using errcode='PT422',message='Verified guardian required'; end;
  select * into g from public.guardians where id=v_guardian and provider_id=p_provider for share;
  if not found or g.user_id is not null or g.email_status is distinct from 'ok'
    or g.email is distinct from p_recipient or p_recipient is null
    or p_recipient !~ '^[^[:space:]@<>,;:"\\]+@[^[:space:]@<>,;:"\\]+\.[^[:space:]@<>,;:"\\]+$'
    or exists(select 1 from public.email_suppressions where email=lower(p_recipient)) then
    raise exception using errcode='PT422',message='Current deliverable organization guardian required';
  end if;
  if p_from is null or p_from !~ '^[^<>[:cntrl:]]{1,100} <[^<>[:space:]@]+@[^<>[:space:]@]+>$'
    or p_reply_to is null or p_reply_to !~ '^[^[:space:]@<>,;:"\\]+@[^[:space:]@<>,;:"\\]+\.[^[:space:]@<>,;:"\\]+$'
    or p_subject is null or length(p_subject) not between 1 and 200 or p_subject ~ '[[:cntrl:]]'
    or (nullif(m.content->>'subject','') is not null and p_subject is distinct from m.content->>'subject')
    or p_unsubscribe_url is null or p_unsubscribe_url !~
      ('^https://[^[:space:]<>/?#]+/functions/v1/unsubscribe[?]g='||v_guardian::text||'&t=[a-f0-9]{32}$') then
    raise exception using errcode='PT422',message='Validated sender, subject and signed unsubscribe envelope required';
  end if;
  -- Source then provider/assignment/quota locks match the other sender RPCs.
  -- Retrying a reserved message rechecks the current catalog, including downgrade.
  v_claim:=public.reserve_message_send_quota_internal(p_provider,'outbound',p_message);
  select e.branding_footer into strict v_branding from public.plan_entitlements e
    where e.plan=(public.resolve_provider_entitlements_internal(p_provider)->>'effective_plan') for share;
  v_text:=m.content->>'body';
  if v_branding then v_text:=v_text||E'\n\nSent via Sporv'; end if;
  v_text:=v_text||E'\n\nUnsubscribe from these messages: '||p_unsubscribe_url;
  v_wire:=jsonb_build_object('from',p_from,'reply_to',p_reply_to,'to',jsonb_build_array(p_recipient),
    'subject',p_subject,'text',v_text,'headers',jsonb_build_object('X-Sporv-Message-Id',p_message::text,
      'List-Unsubscribe','<'||p_unsubscribe_url||'>','List-Unsubscribe-Post','List-Unsubscribe=One-Click'))::text;
  if d.id is not null then
    if d.wire_body<>v_wire or d.quota_claim_id<>v_claim or d.guardian_id<>v_guardian then
      raise exception using errcode='PT409',message='Retry envelope or entitlement changed; human review required';
    end if;
    v_key:=d.idempotency_key; v_ordinal:=d.attempt_count+1;
    update public.outbound_email_dispatches set state='dispatching',active_attempt=v_attempt,
      attempt_count=attempt_count+1,retry_after=null where id=d.id and state='retry_wait' returning * into d;
  else
    v_key:='sporv/email/'||gen_random_uuid()::text; v_ordinal:=1;
    insert into public.outbound_email_dispatches(message_id,provider_id,actor_id,approved_at,approved_content,
      guardian_id,recipient,quota_claim_id,branding_footer,wire_body,wire_sha256,idempotency_key,state,active_attempt,attempt_count)
    values(p_message,p_provider,p_actor,p_approved_at,p_expected_content,v_guardian,p_recipient,v_claim,v_branding,
      v_wire,encode(sha256(convert_to(v_wire,'UTF8')),'hex'),v_key,'dispatching',v_attempt,v_ordinal)
    returning * into d;
  end if;
  if d.id is null or d.active_attempt is distinct from v_attempt or d.state is distinct from 'dispatching'
    or d.message_id is distinct from p_message or d.provider_id is distinct from p_provider
    or d.actor_id is distinct from p_actor or d.approved_at is distinct from p_approved_at
    or d.approved_content is distinct from p_expected_content or d.guardian_id is distinct from v_guardian
    or d.recipient is distinct from p_recipient or d.quota_claim_id is distinct from v_claim
    or d.wire_body is distinct from v_wire or d.wire_sha256 is distinct from encode(sha256(convert_to(v_wire,'UTF8')),'hex')
    or d.branding_footer is distinct from v_branding or d.idempotency_key is distinct from v_key
    or d.attempt_count is distinct from v_ordinal or d.retry_after is not null then
    raise exception using errcode='PT503',message='Email dispatch did not persist';
  end if;
  insert into public.outbound_email_attempts(id,dispatch_id,ordinal) values(v_attempt,d.id,d.attempt_count);
  if not exists(select 1 from public.outbound_email_attempts where id=v_attempt and dispatch_id=d.id and ordinal=d.attempt_count) then
    raise exception using errcode='PT503',message='Email attempt receipt missing';
  end if;
  update public.outbound_messages set status='processing',attempt_count=d.attempt_count,last_error=null
    where id=p_message and provider_id=p_provider and status='approved' and sent_at is null;
  get diagnostics v_rows=row_count;
  if v_rows<>1 or not exists(select 1 from public.outbound_messages where id=p_message and provider_id=p_provider
    and status='processing' and approved_by=p_actor and approved_at=p_approved_at and content=p_expected_content
    and attempt_count=d.attempt_count and sent_at is null) then
    raise exception using errcode='PT503',message='Email processing claim did not persist';
  end if;
  v_receipt:=public.email_dispatch_receipt_internal(d.id,'ready');
  if v_receipt is null then raise exception using errcode='PT503',message='Email dispatch receipt missing'; end if;
  return v_receipt;
end $$;
revoke all on function public.prepare_approved_lifecycle_email(uuid,uuid,uuid,timestamptz,jsonb,text,text,text,text,text)
  from public,anon,authenticated;
grant execute on function public.prepare_approved_lifecycle_email(uuid,uuid,uuid,timestamptz,jsonb,text,text,text,text,text) to service_role;

create function public.record_lifecycle_email_result(
  p_dispatch uuid,p_attempt uuid,p_provider uuid,p_wire_sha256 text,p_outcome text,
  p_provider_message_id text default null,p_retry_after timestamptz default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  d public.outbound_email_dispatches%rowtype; m public.outbound_messages%rowtype;
  r public.outbound_email_results%rowtype; v_message uuid; v_rows integer; v_now timestamptz:=clock_timestamp();
begin
  if p_dispatch is null or p_attempt is null or p_provider is null or p_outcome is null
    or p_outcome not in ('accepted','retry_wait','ambiguous','rejected') then
    raise exception using errcode='PT422',message='Validated email outcome required';
  end if;
  -- Obtain the immutable source id, then use the SAME source-first lock order.
  select message_id into v_message from public.outbound_email_dispatches where id=p_dispatch and provider_id=p_provider;
  if not found then raise exception using errcode='42501',message='Email dispatch organization mismatch'; end if;
  select * into m from public.outbound_messages where id=v_message and provider_id=p_provider for update;
  if not found then raise exception using errcode='PT503',message='Email source missing'; end if;
  select * into d from public.outbound_email_dispatches where id=p_dispatch and provider_id=p_provider for update;
  if d.wire_sha256 is distinct from p_wire_sha256 or not exists(select 1 from public.outbound_email_attempts
    where id=p_attempt and dispatch_id=d.id) then
    raise exception using errcode='PT409',message='Email attempt snapshot mismatch';
  end if;
  select * into r from public.outbound_email_results where attempt_id=p_attempt;
  if found then
    if r.outcome is distinct from p_outcome or r.provider_message_id is distinct from p_provider_message_id
      or r.retry_after is distinct from p_retry_after then
      raise exception using errcode='PT409',message='Conflicting email outcome; reconciliation required';
    end if;
    return jsonb_build_object('kind','already_recorded','result_id',r.id,'attempt_id',r.attempt_id,
      'dispatch_id',r.dispatch_id,'outcome',r.outcome,'provider_message_id',r.provider_message_id,'created_at',r.created_at);
  end if;
  if d.active_attempt<>p_attempt or d.state<>'dispatching' or m.status<>'processing' or m.sent_at is not null
    or m.approved_by is distinct from d.actor_id or m.approved_at is distinct from d.approved_at
    or m.content is distinct from d.approved_content then
    raise exception using errcode='PT409',message='Active email dispatch changed; reconciliation required';
  end if;
  if (p_outcome='accepted')<>(p_provider_message_id is not null)
    or (p_provider_message_id is not null and p_provider_message_id !~ '^[A-Za-z0-9_-]{1,200}$')
    or (p_outcome='retry_wait')<>(p_retry_after is not null)
    or (p_retry_after is not null and (p_retry_after<v_now+interval '30 seconds' or p_retry_after>v_now+interval '7 days')) then
    raise exception using errcode='PT422',message='Invalid provider receipt or retry deadline';
  end if;
  insert into public.outbound_email_results(attempt_id,dispatch_id,outcome,provider_message_id,retry_after,created_at)
    values(p_attempt,d.id,p_outcome,p_provider_message_id,p_retry_after,v_now) returning * into r;
  if r.id is null or r.attempt_id is distinct from p_attempt or r.dispatch_id is distinct from d.id
    or r.outcome is distinct from p_outcome or r.provider_message_id is distinct from p_provider_message_id
    or r.retry_after is distinct from p_retry_after or r.created_at is distinct from v_now then
    raise exception using errcode='PT503',message='Email result did not persist exactly';
  end if;
  if p_outcome='accepted' then
    -- Acceptance is historical fact even if the subscription changed in flight.
    -- Never re-deny it or consume a second quota slot after the provider accepted.
    perform public.accept_message_send_quota_internal(d.quota_claim_id,p_provider,r.id);
    update public.outbound_messages set status='sent',sent_at=r.created_at,provider='resend',
      provider_message_id=p_provider_message_id,last_error=null where id=m.id;
  else
    update public.outbound_messages set status=case when p_outcome='retry_wait' then 'approved' else 'needs_review' end,
      send_after=case when p_outcome='retry_wait' then p_retry_after else send_after end,
      last_error=case p_outcome when 'retry_wait' then 'email_provider_rate_limited'
        when 'rejected' then 'email_provider_rejected' else 'email_delivery_unconfirmed' end where id=m.id;
  end if;
  get diagnostics v_rows=row_count;
  if v_rows<>1 or not exists(select 1 from public.outbound_messages o where o.id=m.id and o.provider_id=p_provider
    and o.approved_by=d.actor_id and o.approved_at=d.approved_at and o.content=d.approved_content
    and (case when p_outcome='accepted' then o.status='sent' and o.sent_at=r.created_at and o.provider='resend'
      and o.provider_message_id=p_provider_message_id and o.last_error is null
    when p_outcome='retry_wait' then o.status='approved' and o.sent_at is null and o.send_after=p_retry_after
      and o.last_error='email_provider_rate_limited'
    else o.status='needs_review' and o.sent_at is null and o.last_error=
      case when p_outcome='rejected' then 'email_provider_rejected' else 'email_delivery_unconfirmed' end end)) then
    raise exception using errcode='PT503',message='Email outcome projection did not persist';
  end if;
  update public.outbound_email_dispatches set state=p_outcome,retry_after=p_retry_after where id=d.id and active_attempt=p_attempt;
  get diagnostics v_rows=row_count;
  if v_rows<>1 or not exists(select 1 from public.outbound_email_dispatches where id=d.id
    and active_attempt=p_attempt and state=p_outcome and retry_after is not distinct from p_retry_after) then
    raise exception using errcode='PT503',message='Email dispatch outcome did not persist';
  end if;
  return jsonb_build_object('kind','recorded','result_id',r.id,'attempt_id',r.attempt_id,'dispatch_id',r.dispatch_id,
    'outcome',r.outcome,'provider_message_id',r.provider_message_id,'created_at',r.created_at);
end $$;
revoke all on function public.record_lifecycle_email_result(uuid,uuid,uuid,text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.record_lifecycle_email_result(uuid,uuid,uuid,text,text,text,timestamptz) to service_role;

-- Blocks direct sent-state bypass, including a service client falling back to
-- the former independent UPDATE. Existing historical rows are not rewritten.
create function public.guard_email_sent_projection() returns trigger language plpgsql set search_path='' as $$
begin
  if new.provider='resend' and new.sent_at is not null and (tg_op='INSERT' or
    (new.status,new.sent_at,new.provider,new.provider_message_id,new.approved_by,new.approved_at,new.content,new.provider_id)
      is distinct from (old.status,old.sent_at,old.provider,old.provider_message_id,old.approved_by,old.approved_at,old.content,old.provider_id)) then
    if not exists(select 1 from public.outbound_email_results r join public.outbound_email_dispatches d on d.id=r.dispatch_id
      where d.message_id=new.id and d.provider_id=new.provider_id and d.actor_id=new.approved_by
        and d.approved_at=new.approved_at and d.approved_content=new.content
        and r.outcome='accepted' and r.provider_message_id=new.provider_message_id
        and r.created_at=new.sent_at and new.status='sent') then
      raise exception using errcode='42501',message='Durable approved email acceptance receipt required';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.guard_email_sent_projection() from public,anon,authenticated,service_role;
create trigger outbound_email_sent_receipt before insert or update on public.outbound_messages
  for each row execute function public.guard_email_sent_projection();
commit;
