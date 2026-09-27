-- [CRITICAL-PATH] REVIEW DRAFT — NOT APPLIED.
-- Requires send-quota.sql and lifecycle-approval.sql; deploy with the worker.
-- Delivery ONLY: the original human approval must already exist and cannot
-- change. No cron token, client parameter or missing approval grants approval.
-- Quota, inbox, immutable receipt and sent state commit or roll back together.
-- Inverse: rollback before acceptance; afterwards an approved correction only.
begin;
create function public.deliver_approved_lifecycle_inbox(
  p_message uuid,p_provider uuid,p_actor uuid,p_approved_at timestamptz,
  p_expected_content jsonb,p_recipient uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_message public.outbound_messages%rowtype;
  v_receipt public.outbound_inbox_send_receipts%rowtype;
  v_notification public.notifications%rowtype;
  v_owner uuid; v_guardian uuid; v_claimed uuid; v_result jsonb;
begin
  if p_message is null or p_provider is null or p_actor is null or p_recipient is null
    or p_approved_at is null then
    raise exception using errcode='PT409',message='Existing human approval and recipient required';
  end if;
  select * into v_message from public.outbound_messages
    where id=p_message and provider_id=p_provider for update;
  if not found then raise exception using errcode='42501',message='Message organization mismatch'; end if;
  select owner_id into v_owner from public.providers where id=p_provider for share;
  if v_owner is distinct from p_actor then
    raise exception using errcode='42501',message='Original approving owner required';
  end if;
  if v_message.status not in ('approved','sent') or v_message.approved_by is distinct from p_actor
    or v_message.approved_at is distinct from p_approved_at
    or v_message.content is distinct from p_expected_content
    or jsonb_typeof(v_message.content) is distinct from 'object'
    or jsonb_typeof(v_message.content->'body') is distinct from 'string'
    or nullif(btrim(v_message.content->>'body'),'') is null then
    raise exception using errcode='PT409',message='Approved snapshot changed; human review required';
  end if;
  if (v_message.status='approved' and v_message.sent_at is not null)
    or (v_message.status='sent' and (v_message.provider is distinct from 'in-app' or v_message.sent_at is null)) then
    raise exception using errcode='PT409',message='Delivery state requires reconciliation';
  end if;
  if v_message.status='approved' then
    begin v_guardian:=(v_message.content->>'guardian_id')::uuid;
    exception when invalid_text_representation then
      raise exception using errcode='PT422',message='Verified organization guardian required';
    end;
    select user_id into v_claimed from public.guardians
      where id=v_guardian and provider_id=p_provider for share;
    if not found or v_claimed is distinct from p_recipient then
      raise exception using errcode='PT422',message='Claimed guardian changed; human review required';
    end if;
  end if;
  -- The source lock and strict preconditions above mean this invocation can
  -- only deliver/replay an existing approval, never create or edit an approval.
  -- The inner transaction still verifies child/booking/roster relationships.
  v_result:=public.approve_lifecycle_message_entitled(p_message,p_actor,p_expected_content,
    v_message.content->>'body','[]'::jsonb);
  if jsonb_typeof(v_result) is distinct from 'object' or v_result->>'kind' is null
    or v_result->>'kind' not in ('sent','already_sent')
    or v_result->>'id' is distinct from p_message::text
    or v_result->>'status' is distinct from 'sent' then
    raise exception using errcode='PT503',message='Inbox transaction receipt missing';
  end if;
  select * into v_receipt from public.outbound_inbox_send_receipts
    where id=(v_result->>'receipt_id')::uuid and message_id=p_message and provider_id=p_provider
      and actor_id=p_actor and recipient_id=p_recipient;
  if not found or v_receipt.body_sha256 is distinct from
    encode(sha256(convert_to(v_message.content->>'body','UTF8')),'hex') then
    raise exception using errcode='PT503',message='Inbox transaction identity mismatch';
  end if;
  select * into v_notification from public.notifications
    where id=v_receipt.notification_id and user_id=p_recipient;
  if not found or (v_result->>'kind'='sent' and
    (v_notification.title is distinct from v_result->>'title'
      or v_notification.message is distinct from v_result->>'preview')) then
    raise exception using errcode='PT503',message='Inbox notification receipt mismatch';
  end if;
  if not exists(select 1 from public.outbound_messages where id=p_message and provider_id=p_provider
      and approved_by=p_actor and approved_at=p_approved_at and content=p_expected_content
      and status='sent' and sent_at=v_receipt.accepted_at and provider='in-app') then
    raise exception using errcode='PT503',message='Original approval or delivery transition changed';
  end if;
  return v_result||jsonb_build_object('provider_id',p_provider,'approved_by',p_actor,
    'approved_at',p_approved_at,'body_sha256',v_receipt.body_sha256,
    'sent_at',v_receipt.accepted_at,'notification_id',v_receipt.notification_id,'recipient_id',v_receipt.recipient_id);
end;
$$;
revoke all on function public.deliver_approved_lifecycle_inbox(uuid,uuid,uuid,timestamptz,jsonb,uuid)
  from public,anon,authenticated;
grant execute on function public.deliver_approved_lifecycle_inbox(uuid,uuid,uuid,timestamptz,jsonb,uuid) to service_role;
commit;
