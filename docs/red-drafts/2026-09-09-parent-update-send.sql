-- [CRITICAL-PATH] REVIEW DRAFT, NOT DEPLOYED.
-- Requires the reviewed plan-entitlements catalog/resolver and send-quota.sql. Deploy with the
-- parent-update-send caller, never before its disposable SQL fixture passes.
-- Release hold: lifecycle-approve/process must join the same provider lock and
-- quota accounting before this is advertised as a system-wide send hard stop.
-- This transaction protects the parent-update inbox path only.
-- Precondition: verified owner, owner-approved content, verified booking/family,
-- available quota. Receipt: immutable inbox_send_receipts + notifications row.
-- Inverse: a delivered inbox message cannot be unread; issue an explicitly
-- approved correction. Failed transactions roll back notification and quota.
-- Code rollback: restore the previous edge function only alongside a reviewed
-- database rollback; retain receipts, never erase accepted-delivery evidence.
begin;

create table public.inbox_send_receipts (
  id uuid primary key default gen_random_uuid(),
  parent_update_id uuid not null unique,
  provider_id uuid not null,
  actor_id uuid not null,
  recipient_id uuid not null,
  notification_id uuid not null unique,
  summary_sha256 text not null check (summary_sha256 ~ '^[a-f0-9]{64}$'),
  accepted_at timestamptz not null,
  quota_month date not null,
  check (quota_month = (date_trunc('month',accepted_at at time zone 'UTC'))::date)
);
-- Deliberately no cascading FKs: deleting a source or notification must not
-- erase a send or replenish quota. No message body is duplicated here.
create index inbox_send_receipts_month on public.inbox_send_receipts(provider_id,quota_month);
create index if not exists parent_updates_send_month on public.parent_updates(provider_id,sent_at) where sent_at is not null;
create index if not exists outbound_messages_send_month on public.outbound_messages(provider_id,sent_at) where sent_at is not null;
alter table public.inbox_send_receipts enable row level security;
revoke all on public.inbox_send_receipts from public,anon,authenticated,service_role;
grant select on public.inbox_send_receipts to service_role;

create function public.inbox_send_receipt_immutable()
returns trigger language plpgsql set search_path='' as $$
begin raise exception using errcode='55000',message='Send receipts are append-only'; end;
$$;
revoke all on function public.inbox_send_receipt_immutable() from public,anon,authenticated,service_role;
create trigger inbox_send_receipt_immutable before update or delete on public.inbox_send_receipts
for each row execute function public.inbox_send_receipt_immutable();

create function public.guard_parent_update_send_receipt()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' and old.status='sent' and
    (new.provider_id,new.child_id,new.summary_body,new.approved_by,new.approved_at,new.status,new.sent_at,new.delivery_channel)
    is distinct from
    (old.provider_id,old.child_id,old.summary_body,old.approved_by,old.approved_at,old.status,old.sent_at,old.delivery_channel) then
    raise exception using errcode='55000',message='A delivered update requires an explicit correction';
  end if;
  if new.status='sent' and (tg_op='INSERT' or old.status is distinct from 'sent') then
    if not exists (
      select 1 from public.inbox_send_receipts r
      join public.notifications n on n.id=r.notification_id and n.user_id=r.recipient_id
      join public.athletes a on a.id=new.child_id and a.parent_id=r.recipient_id
      where r.parent_update_id=new.id and r.provider_id=new.provider_id
        and r.actor_id=new.approved_by and r.accepted_at=new.sent_at
        and new.delivery_channel='inbox'
        and r.summary_sha256=encode(sha256(convert_to(new.summary_body,'UTF8')),'hex')
    ) then
      raise exception using errcode='42501',message='Verified send receipt required';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_parent_update_send_receipt() from public,anon,authenticated,service_role;
create trigger parent_update_send_receipt before insert or update on public.parent_updates
for each row execute function public.guard_parent_update_send_receipt();

create function public.send_parent_update_entitled(p_update_id uuid,p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_update public.parent_updates%rowtype;
  v_receipt public.inbox_send_receipts%rowtype;
  v_owner uuid; v_recipient uuid; v_first_name text;
  v_ent jsonb; v_branding boolean; v_quota_claim uuid;
  v_notification uuid; v_title text; v_preview text; v_now timestamptz := clock_timestamp();
  v_month date := date_trunc('month',v_now at time zone 'UTC')::date;
  v_rows integer;
begin
  if p_actor_id is null or p_update_id is null then
    raise exception using errcode='PT400',message='Update and actor are required';
  end if;
  -- Missing and inaccessible IDs have the same response; no tenant enumeration.
  select u.* into v_update from public.parent_updates u
    join public.providers p on p.id=u.provider_id and p.owner_id=p_actor_id
    where u.id=p_update_id for update of u;
  if not found then raise exception using errcode='42501',message='Update access required'; end if;
  select owner_id into v_owner from public.providers where id=v_update.provider_id for share;
  if v_owner is distinct from p_actor_id then
    raise exception using errcode='42501',message='Update access required';
  end if;
  select * into v_receipt from public.inbox_send_receipts where parent_update_id=p_update_id;
  if found then
    if v_update.status<>'sent' or v_update.sent_at is distinct from v_receipt.accepted_at
       or v_receipt.provider_id<>v_update.provider_id or v_receipt.actor_id<>p_actor_id
       or encode(sha256(convert_to(v_update.summary_body,'UTF8')),'hex') is distinct from v_receipt.summary_sha256 then
      raise exception using errcode='PT503',message='Send receipt requires reconciliation';
    end if;
    return jsonb_build_object('kind','already_sent','id',p_update_id,'receipt_id',v_receipt.id,
      'notification_id',v_receipt.notification_id,'recipient_id',v_receipt.recipient_id,
      'status','sent','sent_at',v_receipt.accepted_at,'delivery_channel','inbox');
  end if;
  -- Legacy sent rows without an atomic receipt are not resent or called proven.
  if v_update.status<>'approved' or v_update.approved_by is distinct from p_actor_id
     or v_update.approved_at is null or v_update.sent_at is not null then
    raise exception using errcode='PT409',message='An approved unsent update is required';
  end if;
  if nullif(btrim(v_update.summary_body),'') is null then
    raise exception using errcode='PT422',message='Approved content is required';
  end if;
  -- A child UUID alone is not a tenant relationship. If a booking is named,
  -- it must match; never fall back from a bad booking to a looser roster check.
  if v_update.booking_id is not null then
    select a.parent_id,a.first_name into v_recipient,v_first_name
      from public.bookings b join public.programs p on p.id=b.program_id
      join public.sessions s on s.id=b.session_id and s.program_id=p.id
      join public.athletes a on a.id=b.athlete_id and a.parent_id=b.searcher_id
      where b.id=v_update.booking_id and a.id=v_update.child_id
        and p.provider_id=v_update.provider_id and b.status='completed'
      for share of a,b,p,s;
  else
    -- Club members need no booking or team assignment. Use the actual tenant
    -- roster identity, not an imported display-name guess or another org's row.
    select a.parent_id,a.first_name into v_recipient,v_first_name
      from public.team_athletes m join public.athletes a on a.id=m.athlete_id
      where m.provider_id=v_update.provider_id and a.id=v_update.child_id
      order by m.id limit 1 for share of a,m;
  end if;
  if v_recipient is null then raise exception using errcode='PT422',message='Verified family relationship required'; end if;

  v_quota_claim:=public.reserve_message_send_quota_internal(v_update.provider_id,'parent_update',p_update_id);
  v_now := clock_timestamp();
  v_month := date_trunc('month',v_now at time zone 'UTC')::date;
  v_ent := public.resolve_provider_entitlements_internal(v_update.provider_id);
  select e.branding_footer into strict v_branding
    from public.plan_entitlements e where e.plan=v_ent->>'effective_plan' for share;
  v_title := 'New progress update for '||coalesce(nullif(v_first_name,''),'your athlete');
  v_preview := left(v_update.summary_body,140);
  if v_branding then v_preview:=v_preview||E'\n\nSent via Sporv'; end if;
  insert into public.notifications(user_id,title,message) values(v_recipient,v_title,v_preview) returning id into v_notification;
  if v_notification is null or not exists(select 1 from public.notifications
    where id=v_notification and user_id=v_recipient and title=v_title and message=v_preview) then
    raise exception using errcode='PT503',message='Notification receipt missing';
  end if;
  insert into public.inbox_send_receipts(parent_update_id,provider_id,actor_id,recipient_id,notification_id,
    summary_sha256,accepted_at,quota_month) values(p_update_id,v_update.provider_id,p_actor_id,v_recipient,v_notification,
    encode(sha256(convert_to(v_update.summary_body,'UTF8')),'hex'),v_now,v_month) returning * into v_receipt;
  if v_receipt.id is null then raise exception using errcode='PT503',message='Send receipt missing'; end if;
  perform public.accept_message_send_quota_internal(v_quota_claim,v_update.provider_id,v_receipt.id);
  update public.parent_updates set status='sent',sent_at=v_now,delivery_channel='inbox'
    where id=p_update_id and status='approved' and approved_by=p_actor_id and sent_at is null;
  get diagnostics v_rows=row_count;
  if v_rows<>1 or not exists(select 1 from public.parent_updates where id=p_update_id and status='sent'
      and sent_at=v_now and delivery_channel='inbox' and approved_by=p_actor_id
      and provider_id=v_update.provider_id and child_id=v_update.child_id and summary_body=v_update.summary_body) then
    raise exception using errcode='PT503',message='Send transition did not persist';
  end if;
  return jsonb_build_object('kind','sent','id',p_update_id,'receipt_id',v_receipt.id,
    'notification_id',v_notification,'recipient_id',v_recipient,'status','sent','sent_at',v_now,
    'delivery_channel','inbox','title',v_title,'preview',v_preview);
end;
$$;
revoke all on function public.send_parent_update_entitled(uuid,uuid) from public,anon,authenticated;
grant execute on function public.send_parent_update_entitled(uuid,uuid) to service_role;
commit;
