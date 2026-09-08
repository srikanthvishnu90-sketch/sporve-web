-- RED DRAFT (migration) — Supabase performance advisor 2026-09-08.
-- Findings: 55 unindexed foreign keys, 2 duplicate indexes, 1 table without a
-- primary key, 119 RLS policies that re-evaluate auth.uid() per row.
-- Nothing here changes what anyone can read or write. Every statement is
-- additive or a pure rewrite; the inverse of each is stated inline.
-- Part D (the 119 policies) is the one to read carefully: it rewrites policy
-- expressions mechanically and MUST be run with the .test.sql dry-run first.
-- "multiple_permissive_policies" (24) is accepted as designed: owner-vs-guardian
-- and owner-vs-public reads are two audiences on one table on purpose.
begin;

-- A. Foreign-key indexes (55). Inverse: drop index if exists <name>.
-- Every join the agent generators and the queue make walks one of these.
create index if not exists idx_agent_findings_member on public.agent_findings (member_id);
create index if not exists idx_agent_proposals_applied_by on public.agent_proposals (applied_by);
create index if not exists idx_agent_proposals_why on public.agent_proposals (why_finding_id);
create index if not exists idx_ai_audit_log_approved_by on public.ai_audit_log (approved_by);
create index if not exists idx_bookings_athlete on public.bookings (athlete_id);
create index if not exists idx_bookings_cancelled_by on public.bookings (cancelled_by);
create index if not exists idx_bookings_program on public.bookings (program_id);
create index if not exists idx_coach_invites_inviter on public.coach_invites (inviter_owner_id);
create index if not exists idx_conversations_program on public.conversations (program_id);
create index if not exists idx_delivery_events_guardian on public.delivery_events (guardian_id);
create index if not exists idx_delivery_events_message on public.delivery_events (message_id);
create index if not exists idx_disputes_decided_by on public.disputes (decided_by);
create index if not exists idx_disputes_proposed_session on public.disputes (proposed_session_id);
create index if not exists idx_facilities_added_by on public.facilities (added_by);
create index if not exists idx_facility_notes_provider on public.facility_notes (provider_id);
create index if not exists idx_fee_schedules_program on public.fee_schedules (program_id);
create index if not exists idx_fee_schedules_season on public.fee_schedules (season_id);
create index if not exists idx_guardian_links_guardian_org on public.guardian_links (guardian_id, provider_id);
create index if not exists idx_guardian_links_member_org on public.guardian_links (member_id, provider_id);
create index if not exists idx_guardians_user on public.guardians (user_id);
create index if not exists idx_import_batches_created_by on public.import_batches (created_by);
create index if not exists idx_installments_member on public.installments (member_id);
create index if not exists idx_lmp_updated_by on public.lifecycle_message_prefs (updated_by);
create index if not exists idx_messages_sender on public.messages (sender_id);
create index if not exists idx_obligations_approved_by on public.obligations (approved_by);
create index if not exists idx_obligations_created_by on public.obligations (created_by);
create index if not exists idx_obligations_guardian on public.obligations (guardian_id);
create index if not exists idx_obligations_member on public.obligations (member_id);
create index if not exists idx_obligations_team on public.obligations (team_id);
create index if not exists idx_obligations_why on public.obligations (why_finding_id);
create index if not exists idx_outbound_messages_approved_by on public.outbound_messages (approved_by);
create index if not exists idx_outbound_messages_obligation on public.outbound_messages (obligation_id);
create index if not exists idx_parent_updates_approved_by on public.parent_updates (approved_by);
create index if not exists idx_parent_updates_booking on public.parent_updates (booking_id);
create index if not exists idx_ledger_reverses_entry on public.payment_event_ledger (reverses_entry_id);
create index if not exists idx_plan_proposals_provider on public.plan_proposals (provider_id);
create index if not exists idx_plan_proposals_service on public.plan_proposals (service_id);
create index if not exists idx_privacy_requests_requester on public.privacy_requests (requester_id);
create index if not exists idx_program_waitlist_athlete on public.program_waitlist (athlete_id);
create index if not exists idx_pds_session_note on public.progress_digest_sources (session_note_id);
create index if not exists idx_provider_settings_updated_by on public.provider_settings (updated_by);
create index if not exists idx_refund_requests_requester on public.refund_requests (requester_id);
create index if not exists idx_reviews_author on public.reviews (author_id);
create index if not exists idx_reviews_reviewee on public.reviews (reviewee_id);
create index if not exists idx_safety_reports_booking on public.safety_reports (booking_id);
create index if not exists idx_safety_reports_conversation on public.safety_reports (conversation_id);
create index if not exists idx_safety_reports_provider on public.safety_reports (provider_id);
create index if not exists idx_safety_reports_reporter on public.safety_reports (reporter_id);
create index if not exists idx_settings_audit_changed_by on public.settings_audit (changed_by);
create index if not exists idx_settings_audit_provider on public.settings_audit (provider_id);
create index if not exists idx_staff_certifications_attested_by on public.staff_certifications (attested_by);
create index if not exists idx_team_athletes_season on public.team_athletes (season_id);
create index if not exists idx_teams_season on public.teams (season_id);
create index if not exists idx_waiver_signatures_guardian on public.waiver_signatures (guardian_id);
create index if not exists idx_waiver_signatures_season on public.waiver_signatures (season_id);

-- B. Duplicate indexes (2). The *_key ones back UNIQUE constraints and stay;
-- the hand-made twins go. Inverse: recreate as plain indexes on the same column.
drop index if exists public.idx_coach_invites_token;
drop index if exists public.uq_ledger_event;

-- C. waitlist_rate_limit has no primary key (advisor no_primary_key). Rows are
-- (ip, ts) events; a surrogate key makes them addressable for GC and replication.
-- Inverse: alter table public.waitlist_rate_limit drop column id.
alter table public.waitlist_rate_limit add column if not exists id bigint generated by default as identity;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.waitlist_rate_limit'::regclass and contype='p') then
    alter table public.waitlist_rate_limit add primary key (id);
  end if;
end $$;

-- D. auth_rls_initplan (119 policies). Postgres re-runs auth.uid() for every
-- row unless it is written as (select auth.uid()), which is evaluated once
-- per statement. This rewrites every policy expression in public that calls
-- auth.uid() / auth.role() / auth.jwt() bare, keeping the same command, roles
-- and semantics. Run 2026-09-08-performance-advisors.test.sql FIRST — it lists
-- exactly what would change without changing it.
-- Inverse: the same loop with the replacement reversed.
do $$
declare r record; v_using text; v_check text; v_sql text;
begin
  for r in
    select schemaname, tablename, policyname, cmd, roles, qual, with_check
    from pg_policies
    where schemaname='public'
      and (coalesce(qual,'')||coalesce(with_check,'')) ~* '(?<!select\s)auth\.(uid|role|jwt)\(\)'
  loop
    v_using := regexp_replace(r.qual, '(?<!select\s)auth\.(uid|role|jwt)\(\)', '(select auth.\1())', 'gi');
    v_check := regexp_replace(r.with_check, '(?<!select\s)auth\.(uid|role|jwt)\(\)', '(select auth.\1())', 'gi');
    v_sql := format('alter policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
    if v_using is not null then v_sql := v_sql || format(' using (%s)', v_using); end if;
    if v_check is not null then v_sql := v_sql || format(' with check (%s)', v_check); end if;
    execute v_sql;
  end loop;
end $$;

commit;
