-- [CRITICAL-PATH] REVIEW DRAFT — NOT APPLIED.
-- Requires send-quota.sql + plan catalog. Deploy with lifecycle-approve and
-- lifecycle-process cutover, never alone. Email approval reserves, not sends.
-- Preconditions: verified owner, exact reviewed draft snapshot, valid family,
-- nonempty guardrailed text, shared quota. Inbox receipt/state commit together.
-- Inverse: rollback before acceptance; after delivery only an approved correction.
begin;
create table public.outbound_inbox_send_receipts (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null unique,
  provider_id uuid not null,
  actor_id uuid not null,
  recipient_id uuid not null,
  notification_id uuid not null unique,
  accepted_at timestamptz not null,
  body_sha256 text not null check (body_sha256 ~ '^[a-f0-9]{64}$')
);
alter table public.outbound_inbox_send_receipts enable row level security;
revoke all on public.outbound_inbox_send_receipts from public,anon,authenticated,service_role;
grant select on public.outbound_inbox_send_receipts to service_role;
create trigger outbound_inbox_send_receipts_immutable before update or delete on public.outbound_inbox_send_receipts
for each row execute function public.guard_send_quota_audit();

create function public.approve_lifecycle_message_entitled(
  p_message uuid,p_actor uuid,p_expected_content jsonb,p_body text,p_removed jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_message public.outbound_messages%rowtype;
  v_receipt public.outbound_inbox_send_receipts%rowtype;
  v_owner uuid; v_recipient uuid; v_guardian uuid; v_first text; v_email text; v_email_status text;
  v_claim uuid; v_notification uuid; v_rows integer; v_branding boolean;
  v_body jsonb; v_title text; v_preview text; v_now timestamptz;
begin
  if p_actor is null or p_message is null then raise exception using errcode='PT400',message='Message and actor required'; end if;
  select m.* into v_message from public.outbound_messages m
    join public.providers p on p.id=m.provider_id and p.owner_id=p_actor
    where m.id=p_message for update of m;
  if not found then raise exception using errcode='42501',message='Message access required'; end if;
  select owner_id into v_owner from public.providers where id=v_message.provider_id for share;
  if v_owner is distinct from p_actor then raise exception using errcode='42501',message='Message access required'; end if;
  select * into v_receipt from public.outbound_inbox_send_receipts where message_id=p_message;
  if found then
    if v_message.status<>'sent' or v_message.sent_at is distinct from v_receipt.accepted_at
      or v_receipt.provider_id<>v_message.provider_id or v_receipt.actor_id<>p_actor
      or encode(sha256(convert_to(v_message.content->>'body','UTF8')),'hex') is distinct from v_receipt.body_sha256 then
      raise exception using errcode='PT503',message='Delivery receipt requires reconciliation';
    end if;
    return jsonb_build_object('kind','already_sent','id',p_message,'status','sent','sent_at',v_receipt.accepted_at,
      'receipt_id',v_receipt.id,'notification_id',v_receipt.notification_id,'recipient_id',v_receipt.recipient_id);
  end if;
  if v_message.status not in ('drafted','approved') or v_message.sent_at is not null then
    raise exception using errcode='PT409',message='Message must be a reviewed unsent draft';
  end if;
  if v_message.content is distinct from p_expected_content then
    raise exception using errcode='PT409',message='Draft changed; review its current content';
  end if;
  if jsonb_typeof(v_message.content) is distinct from 'object' or nullif(btrim(p_body),'') is null
     or length(p_body)>10000 or jsonb_typeof(p_removed) is distinct from 'array' then
    raise exception using errcode='PT422',message='Validated message content required';
  end if;
  if v_message.status='approved' and (v_message.approved_by is distinct from p_actor
    or v_message.approved_at is null or v_message.content->>'body' is distinct from p_body) then
    raise exception using errcode='PT409',message='Existing approval cannot be silently rewritten';
  end if;
  -- Named bookings must match; unbooked rebooking nudges can use completed
  -- history, while ordinary unbooked member messages use exact tenant roster.
  if v_message.child_id is not null then
    if v_message.booking_id is not null then
      select a.parent_id,a.first_name into v_recipient,v_first from public.bookings b
        join public.programs p on p.id=b.program_id
        join public.sessions s on s.id=b.session_id and s.program_id=p.id
        join public.athletes a on a.id=b.athlete_id and a.parent_id=b.searcher_id
        where b.id=v_message.booking_id and a.id=v_message.child_id and p.provider_id=v_message.provider_id
        for share of b,p,s,a;
    elsif v_message.event_type='rebook_nudge' then
      select a.parent_id,a.first_name into v_recipient,v_first from public.bookings b
        join public.programs p on p.id=b.program_id
        join public.athletes a on a.id=b.athlete_id and a.parent_id=b.searcher_id
        where a.id=v_message.child_id and p.provider_id=v_message.provider_id and b.status='completed'
        order by b.id limit 1 for share of b,p,a;
    else
      select a.parent_id,a.first_name into v_recipient,v_first from public.team_athletes m
        join public.athletes a on a.id=m.athlete_id
        where a.id=v_message.child_id and m.provider_id=v_message.provider_id
        order by m.id limit 1 for share of m,a;
    end if;
    if v_recipient is null then raise exception using errcode='PT422',message='Verified family relationship required'; end if;
  else
    begin v_guardian:=(v_message.content->>'guardian_id')::uuid;
    exception when invalid_text_representation then raise exception using errcode='PT422',message='Verified guardian required'; end;
    select g.user_id,g.email,g.email_status into v_recipient,v_email,v_email_status
      from public.guardians g where g.id=v_guardian and g.provider_id=v_message.provider_id for share;
    if not found then raise exception using errcode='PT422',message='Verified organization guardian required'; end if;
    if v_recipient is null and (v_email_status is distinct from 'ok' or nullif(btrim(v_email),'') is null
      or btrim(v_email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
      raise exception using errcode='PT422',message='Guardian needs a deliverable address or claimed account';
    end if;
  end if;
  v_claim:=public.reserve_message_send_quota_internal(v_message.provider_id,'outbound',p_message);
  v_now:=clock_timestamp();
  v_body:=case when v_message.status='drafted' then
    coalesce(v_message.content,'{}'::jsonb)||jsonb_build_object('body',p_body,'removed',p_removed)
    else v_message.content end;
  if v_recipient is null then
    -- Email worker must recheck current address, suppression, window, approval
    -- and immutable provider payload before dispatch. No external call here.
    update public.outbound_messages set content=v_body,status='approved',approved_by=p_actor,
      approved_at=case when v_message.status='drafted' then v_now else approved_at end
      where id=p_message and status in ('drafted','approved') and sent_at is null;
    get diagnostics v_rows=row_count;
    if v_rows<>1 or not exists(select 1 from public.outbound_messages where id=p_message and status='approved'
      and approved_by=p_actor and approved_at is not null and content=v_body and sent_at is null) then
      raise exception using errcode='PT503',message='Approval did not persist';
    end if;
    return jsonb_build_object('kind','queued_email','id',p_message,'status','approved','quota_claim_id',v_claim);
  end if;
  select e.branding_footer into strict v_branding from public.plan_entitlements e
    where e.plan=(public.resolve_provider_entitlements_internal(v_message.provider_id)->>'effective_plan') for share;
  v_title:=case when nullif(v_first,'') is not null then 'Message from your coach about '||v_first
    else coalesce(nullif(v_message.content->>'subject',''),'Message from your club') end;
  v_preview:=left(p_body,280);
  if v_branding then v_preview:=v_preview||E'\n\nSent via Sporv'; end if;
  insert into public.notifications(user_id,title,message) values(v_recipient,v_title,v_preview) returning id into v_notification;
  if v_notification is null or not exists(select 1 from public.notifications where id=v_notification
    and user_id=v_recipient and title=v_title and message=v_preview) then
    raise exception using errcode='PT503',message='Notification receipt missing';
  end if;
  insert into public.outbound_inbox_send_receipts(message_id,provider_id,actor_id,recipient_id,notification_id,accepted_at,body_sha256)
    values(p_message,v_message.provider_id,p_actor,v_recipient,v_notification,v_now,encode(sha256(convert_to(p_body,'UTF8')),'hex'))
    returning * into v_receipt;
  if v_receipt.id is null then raise exception using errcode='PT503',message='Delivery receipt missing'; end if;
  perform public.accept_message_send_quota_internal(v_claim,v_message.provider_id,v_receipt.id);
  update public.outbound_messages set content=v_body,status='sent',approved_by=p_actor,
    approved_at=case when v_message.status='drafted' then v_now else approved_at end,
    sent_at=v_now,provider='in-app' where id=p_message and status in ('drafted','approved') and sent_at is null;
  get diagnostics v_rows=row_count;
  if v_rows<>1 or not exists(select 1 from public.outbound_messages where id=p_message and status='sent'
    and content=v_body and approved_by=p_actor and sent_at=v_now and provider='in-app') then
    raise exception using errcode='PT503',message='Delivery transition did not persist';
  end if;
  return jsonb_build_object('kind','sent','id',p_message,'status','sent','sent_at',v_now,'receipt_id',v_receipt.id,
    'notification_id',v_notification,'recipient_id',v_recipient,'title',v_title,'preview',v_preview);
end;
$$;
revoke all on function public.approve_lifecycle_message_entitled(uuid,uuid,jsonb,text,jsonb) from public,anon,authenticated;
grant execute on function public.approve_lifecycle_message_entitled(uuid,uuid,jsonb,text,jsonb) to service_role;
commit;
