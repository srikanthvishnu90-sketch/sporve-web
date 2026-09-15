# Sporv — Amendment 1 to the Authentication Spec
(Onboarding & Connection Architecture — supersedes §9.3 bullet 1 and routing
implications of §9.2 of sporve-auth-implementation-spec.md.)
Ladder: Gate 12 (migration). SPEC NOW, BUILD AFTER GATE 3 (money) CLOSES.

Three phases:
- Phase 1 Identity (<30s): email+password or Google/Microsoft with openid,email,
  profile only. No connector scope, no plan, no card, no phone. Record which
  OAuth provider+account for later "connect director@org" targeting.
- Phase 2 Value before 2nd ask: roster paste ingestion (textarea) -> agent parses,
  shows FINDINGS not a toast ("34 athletes, 3 teams, 2 missing guardian, 4 no
  waiver"). Alts: CSV upload, forward one email to ingest address. Capture admin-
  hours baseline here (one question, once) — cannot be captured retroactively.
- Phase 3 Connector ladder: sequenced one-at-a-time, each justified by what user
  just saw, ordered by value/consent-cost. Order: 1 Email(gmail.readonly / Graph
  Mail.Read+Mail.Send+offline_access) 2 Stripe Connect 3 Drive/Sheets(drive.file
  NOT drive.readonly) 4 QuickBooks(if used) 5 Twilio SMS(org-level). Progressive
  scope escalation. Every connector shows output <60s. Every step skippable+
  resumable server-side (against org, not browser storage).

Requirements base spec lacks:
3.1 Connections belong to ORG not person: store org_id owner + authorized_by_user_id;
    offboarding revokes personal grants, blocking prompt for re-auth if sole
    authorizer; prompt for 2nd admin authorizer on email+payments.
3.2 Invited members never asked to connect (owner/admin only, server-enforced).
3.3 Upstream revocation (invalid_grant) must NOT sign the user out — mark connector
    disconnected, one-click reconnect, session untouched.
3.4 Unverified users may not connect; make verification fast not optional (send at
    creation, Phase 2 proceeds pending, Phase 3 gated on click).
3.5 Minors' data enters at Phase 2 (paste) — Gate 4 attaches then. One plainly-
    worded authority-over-data checkbox, logged w/ timestamp+user id, before Phase
    2 writes.

Done = measured: acct->first finding <10min (per-org distribution); connector
completion rate per step; resumption rate; baseline capture >=90%.
Build order: Phase1 (specced), then Phase2 paste, then Phase3 email-only end-to-end
with visible output; run with a real design partner before connectors 2-5. First
20 migrations done manually regardless.

NOTE (Claude, for thesis): Amendment §3.3/§3.4 and the org-owned-connection model
align with existing invariants (I1 no-send, connector-registry, cron_secret
fail-closed). BUT the Phase-3 table requests Microsoft Graph **Mail.Send** for
email — this DIRECTLY VIOLATES the repo's FORBIDDEN_SCOPES / invariant I1
(connector-registry.mjs lists Mail.Send as forbidden; Gmail is readonly-only). This
is the same conflict Clo flagged on an earlier prompt. Do not implement Mail.Send.
Also this whole amendment is Gate-12 / build-after-Gate-3 — hold, do not build now.
