# Sporv launch prompts

Recovered 2026-09-10 because the owner's requested path returned GitHub404.
Source: the owner's earlier full six-prompt launch set and subsequently supplied
September9 constitution, now in CONTEXT.md. This is an explicit requirements
recovery, not a claim that the missing file or missing state template was read.
STATE.md alone records progress; this file records the work and acceptance.

The current owner instruction changes execution from "one per session" to
continue sequentially in the same session. Do not mark anything passed from a
commit message. Preserve existing work; verify actual code and current data.
CONTEXT.md supersedes older pricing/product/design specifications. Conflicts
not resolved by that precedence are recorded in
docs/decisions/constitution-adoption-20260909.md, not silently chosen.

## Prompt1 — Payments, plans and server enforcement

Keep database keys free|solo|organization. Labels are Free / Solo / Organization.
Remove the retired club pricing tier, not unrelated organization data.
Prices have one configuration source. The later constitution sets Solo49/month,
490/year; Organization from199/month,1990/year; annual wording is "two months
free". Robin's September10 owner-confirmation record is in
docs/launch-readiness-2026-09-10.md; do not infer add-on confirmation from that
base-price confirmation.

### Entitlements and product requirements

Entitlements, never plan-name comparisons, determine access and limits.
Seed exactly three plan_entitlements rows, with non-null values for:
member_cap, admin_cap, group_cap, connectors text[], jobs text[], modules text[],
scan_mode (nightly|triggered|ondemand), draft_quota_month, send_quota_month,
ask_quota_month, branding_footer. Document the unlimited representation.
Limits must be editable as data without source edits.

- Free: permanent, no card, not an expiring trial;15 members,1 admin,1 group;
  website extraction, CSV and Stripe; nightly money/document findings only;
  no triggered runs, proposals, records or client sourcing;20 draft allowance,
 20 sends/month hard stop,25 Ask/month; roster/dues/waivers; outbound
  "Sent via Sporv"; Connect/dues/export always available.
- Solo:100 members,1 admin, unlimited groups/drafts; Free connectors plus Gmail,
  Google Calendar and a Sporv SMS number with inbound reading; nightly and
  triggered; all read/write jobs, records/proposals/client sourcing; paid sends
  fair-use unlimited;500 Ask/month; booking, packages/credits, notes, progress,
  per-session/package billing; no outbound branding.
- Organization:150 members and5 admin seats included, unlimited groups/drafts,
  paid sends fair-use unlimited;2500 Ask/month then metered; all connectors/jobs
  and on-demand runs; installments, RSVP, invite/registration, team chat,
  eligibility, memberships, capacity/check-in, multi-program and league views;
  done-for-you migration/onboarding; no branding.
- The constitution's athlete-band and seat add-ons need correct, confirmed
  pricing and entitlement arithmetic; >approximately800 athletes is a sales
  conversation, not another plan. No per-camp add-on at launch.
- All reads, exports and dues survive cancellation/downgrade/over-cap. Never
  delete customer data. New gated writes fail until capacity is available.
-14-day no-card Organization trial; server-enforced automatic Free expiry.
  A stored card alone must not invent a paid subscription or chosen plan.
- Free draft overflow must remain visible per the later paywall specification.
  Its contradiction with the literal draft-generation402/hard-stop requirement
  remains recorded, not "fixed" by hiding drafts or marking conflicting checks green.

### Billing architecture

Our subscription is Stripe Billing on the platform; dues are direct charges on
connected accounts, application_fee_amount0. No shared table, webhook handler or
edge function. Create verified recurring monthly/annual prices and confirmed
add-ons; never use the live-only tool connection as a substitute for test mode.

Dedicated billing-webhook: signed checkout.session.completed subscriptions,
subscription created/updated/deleted, invoice.payment_failed; map verified price
IDs to org entitlement assignments within60seconds. A failed invoice writes a
finding; Free only after the dunning window ends, not immediately. Subscription
cancellation retains paid access through period end. Verify ordering, retries,
duplicates, wrong mode/account, immutable receipts and reconciliation.

billing-portal must support card changes, upgrades, downgrades and cancellation.
Checkout, portal and webhook must remain separate from Connect callers. Never
manufacture successful responses while prerequisites are missing.

### Server enforcement

Each member/admin/group limit, unauthorized connector OAuth start, send quota,
Ask quota and non-entitled module write must return HTTP402 with exactly
reason,current_plan,upgrade_to,limit,current. Cover direct authenticated APIs
and direct database paths where applicable, not just UI locks. Never500 or
silent no-op. Enforce atomic concurrent caps. Filter cron jobs and scan mode
before generating; write a finding with real affected counts for quota effects.
Preserve reads/export/dues. Resolve the conflicting draft quota demands
explicitly before declaring that boundary passed.

### Acceptance (P1)

- P1.01: Exactly3 seeded live plan_entitlements rows; every required field populated.
- P1.02: Plan/plan_key string-equality comparison grep returns zero in src/,api/,supabase/.
- P1.03: Free16th member ->402 upgrade_to Solo; Gmail connect ->402; draft21
  behavior and finding proven against the explicitly resolved specification;
  Ask26 ->402. All other listed server gates also tested with exact payloads.
- P1.04: Solo Outlook ->402; Gmail connection succeeds.
- P1.05: Organization permits entitled actions within its purchased capacity;
  no decorative cap or accidental paid send limit. This supersedes the old
  unlimited Enterprise plan definition, not the requirement for enforcement.
- P1.06: Stripe test subscription/relevant cancellation changes entitlements
  within60seconds; failed payment preserves access through dunning and then Free;
  period-end cancellation timing follows the later constitution.
- P1.07: Customer Portal opens and a real test-mode card change succeeds.
- P1.08: Organization ->Free with200 members preserves reads/export/dues,
  prevents new members with402 and deletes nothing.
- P1.09: Billing and Connect share no table/handler/function; grep plus review
  proves old subscription handling is removed from the dues path.
- P1.10: Pricing shows Free and exactly two paid cards, Solo/Organization;
  correct centralized prices, annual wording, no camp charge or club tier.
- P1.11: The remaining requirements above, including trial, branding,
  data-driven caps, add-ons/metering and safe concurrent enforcement, have
  implementation and acceptance evidence, not only the ten headline cases.

Requested original commit intent: three plan states, entitlement-driven,
server-side402, Stripe Billing separated from Connect. Do not put unsupported
completion claims in a commit subject.

## Prompt2 — Grand feature review (audit only)

Produce docs/review/feature-inventory.md. Do not fix features during this audit.
For every feature record implementing files, migrations, tests, UI rendering,
fresh-org behavior, and maturity0–5 (absent,stub,partial,happy-path,
edge-cases,production). Score evidence, never commit claims. Identify claims
unsupported by code.

### Trainer inventory

Public booking; availability; packages/session credits; per-session billing;
progress (goals,PRs,measurements,video); session notes; SMS; inbound messages;
no-show/late-cancel policy; intake; waivers; client sourcing (lapsed,referral,
Places,GBP); multi-currency; non-US Stripe; timezones.

### Team inventory

Roster; installment dues; waivers; eligibility; registration; invite links;
schedule; Google/Apple calendar sync; RSVP/availability; team chat; photo/media;
volunteer/snack signups; sport-specific fields/nouns; migrations from TeamSnap,
SportsEngine,LeagueApps,Spond,Jersey Watch,Sheets; staff eligibility;
tournament/events; multi-team structure.

### Gym/studio inventory

Recurring memberships; freeze/cancel; capacity-based classes; check-in;
self-portal; package/drop-in pricing; multiple locations; instructor payouts.
The later constitution prioritizes teams, then trainers; gyms are third.

### Cross-cutting and replacements

Inventory all30 coverage-matrix agent jobs, all20 Ask features, connectors,
review queue, money/ledger, settings, onboarding/doors, marketing and mobile.
Find the actual coverage specifications; absence is a finding, not permission
to invent feature definitions.

For TeamSnap,SportsEngine,Spond,Sprocket,Jersey Watch,TrueCoach,Mindbody,
Google Sheets and Google Docs: research five daily workflows each, classify
Sporv as does/does worse/does better/does not, with evidence. Spreadsheet
migration is a separate customer need from SportsEngine migration.

### Acceptance (P2)

- P2.01: Trainer table covers every listed feature with all evidence columns.
- P2.02: Team table covers every listed feature with all evidence columns.
- P2.03: Gym table covers every listed feature with all evidence columns.
- P2.04: Complete cross-cutting inventory,30 agent jobs and20 Ask features.
- P2.05: Five evidence-backed workflows for each of nine replacement products.
- P2.06: SELLABLE TODAY (4–5,end-to-end), BLOCKS A SEGMENT (absent/<=2,ranked
  by customers blocked), CLAIMED BUT NOT REAL (UI and commit discrepancies).
- P2.07: Each segment ends yes/no/only-if-X; completed inventory committed,
  no feature edits included in this audit. Zero claimed-but-not-real remains a
  launch gate, not a reason to suppress findings.

Commit intent: evidence-scored feature inventory across three segments.

## Prompt3 — Feature floor, scale and concurrency

Use the inventory; raise each in-scope feature scored<=3 to4+. In ranked
blocker order fix happy path, honest empty state, visible specific error state,
one regression that fails before/passes after, and two simultaneous orgs.
Never hide absent features or fabricate a maturity score.

Build if absent: sport packs; invite/registration; RSVP/availability; threaded
org/team messaging; org SMS number with human-sent drafts; recurring billing
shape; public booking with packages/credits.

### Scale floor

Assume5000 orgs,500000 members,2million installments. Index WHERE/JOIN/ORDER
columns on overdue detection,eligibility,queue,roster and ledger balance.
EXPLAIN ANALYZE all five hot paths; no sequential scan of a table>10000rows.
Balance SUM(ledger) under50ms at2million rows, or a reconciled materialized
running balance that does not replace the authoritative ledger.

Crons batch/checkpoint/resume, isolate org errors and avoid one giant
transaction. External Stripe/Resend/Google/Places calls rate-limit, respect429,
back off, queue and retry. Queue pagination must not render300 overdue rows
at once. Seed realistic5000-org data in an isolated environment; run a full
nightly cycle, record wall time,peak connections and cost; finish within send
window and Supabase capacity. Never load-test production by assumption.

### Acceptance (P3)

- P3.01: Every in-scope inventory feature at4+ with definition-of-done evidence;
  exclusions explicit on the marketing site, never silently removed.
- P3.02: Five EXPLAIN ANALYZE outputs and ledger latency target evidence.
- P3.03: docs/review/scale-test.md records full5000-org load, wall time,
  connections,cost, batching/recovery, send-window/capacity verdict.
- P3.04: Two concurrent approvals ->one send; import during cron ->no duplicate
  members; duplicate Stripe webhook ->one ledger entry; mid-cron downgrade
  enforced on next chunk. Each has a passing actual concurrency test.

Commit intent: feature floor raised and5000-org scale verified, only when true.

## Prompt4 — Security

Write docs/security/pre-launch-audit.md as work proceeds. Each check without
pasted actual evidence fails. Never use a UI lock as proof of API isolation.

### Acceptance (P4)

- P4.01: Every public table has RLS; query rowsecurity=false returns zero.
- P4.02: OrgA owner cannot read OrgB in EVERY org-scoped table, app filters removed.
- P4.03: Guardian cannot read another family's members,installments,ledger,
  signatures or notes.
- P4.04: Staff money/eligibility/settings writes ->403 with valid API tokens.
- P4.05: Findings,drafts and Ask cannot cite another org; similar-data fixture proves it.
- P4.06: DOB,emergency contacts,medical notes only guardians/admins; staff query ->null.
- P4.07: Retention/deletion policy written and mechanically enforced.
- P4.08: Complete member export proven against schema, not a partial bundle.
- P4.09: Secret scan in src/,api/,supabase/functions/,vercel.json and browser
  bundle; no embedded keys or browser service-role access. Literal provider-key
  patterns/environment-variable-name matches reported honestly, not suppressed.
- P4.10: Secrets held only in approved secret stores; rotation procedure documented.
- P4.11: No agent-controlled path grants approval, sends, charges or refunds;
  draft-first trigger enabled and attempted bypass denied. The literal blanket
  prohibition on even human-authorized delivery adapters is a recorded conflict.
- P4.12:25 hostile inputs via Ask,website,email cannot cause unauthorized send,
  non-confirmed writes,cross-org reads or fabricated facts; nightly CI execution.
- P4.13: SSRF rejects internal/mixed IPs,off-domain redirects,oversize,slow-loris.
- P4.14: Stripe,Billing,Resend unsigned webhook requests ->401; replay idempotent.
- P4.15: Every unauthenticated auth/signup/extraction/Ask limit actually triggers.
- P4.16: Every authenticated money/send endpoint rate limit actually triggers.
- P4.17: Magic link<=15min,single-use; refresh rotates; sign-out revokes server-side.
- P4.18: Password minimum12 client AND server.
- P4.19: Google login mode cannot silently create an account.
- P4.20: Unknown/known email sign-in responses and timing avoid enumeration.
- P4.21: Live sporv.ai CSP,HSTS,X-Frame-Options DENY,Referrer-Policy; paste headers.
- P4.22: npm audit zero high/critical; dependency/edge versions pinned.
- P4.23: Supabase PITR enabled; actual restore to branch dated and verified.
- P4.24: All Prompt1 gates retested directly with valid API tokens and exact402.
- P4.25: Audit committed with check counts, evidence, every open finding; no
  unlisted security risk or fake live proof.

Commit intent: pre-launch audit with truthful check/findings counts.

## Prompt5 — Free tier and paywall experience

Four walls, each showing what stopped, exactly what the paid plan gives,
one button: draft/send20,member15,Gmail connector lock,Ask25.
Use contextual real counts, not generic upgrade language; Solo sends have
no monthly hard limit under the later constitution.

At50% usage queue header shows remaining sends;80% banner names quota/reset;
100% keeps generated overflow drafts visible and marked over-limit.
Resolve the hard-generation-stop contradiction rather than hiding work.

Locked tabs retain real structure, greyed with named plan; connector cards
state what data they feed. Upgrade sheet has current plan and annual toggle,
Free plus two paid plans; Checkout ->webhook ->entitlements within60seconds ->
safe automatic retry of the blocked action, same return location, no duplicate
write/payment caused by a repeated retry.

Trial findings at days11,13,14 use actual org counts. Free drop deletes
nothing, preserves dues/export and states what is now blocked.
Settings/Billing shows current plan,all quotas/live usage,next invoice amount
and date,change plan/card,cancel,invoice history through Customer Portal.
Cancellation stays paid through period end; one free-text reason stored.
Build required time-saved instrumentation before paywall release per CONTEXT6.7,
without inventing hours-saved assumptions as measured facts.

### Acceptance (P5)

- P5.01: Free25 drafts ->20 sendable and5 visible marked over-limit, after the
  quota-policy conflict is explicitly resolved.
- P5.02: All four walls have correct contextual copy,plan and working button.
- P5.03: Upgrade from blocked action completes it safely without redoing it.
- P5.04: Days11/13/14 findings fire with real counts.
- P5.05: Cancel preserves paid-period access then Free; reason is stored.
- P5.06: Billing UI live usage matches SQL; portal/card/invoices work; visibility
  thresholds,locked surfaces,trial banner and required instrumentation verified.

Commit intent: visible quotas,paywalls,self-service billing,honest trial end.

## Prompt6 — Final launch readiness

Produce docs/decisions/launch-readiness-FINAL.md. No optional or hidden blockers.
The final production acceptance cannot be credited before both live gates close.

### Acceptance (P6)

- P6.01: docs/gates/delivery-live.md: real mail.sporv.ai delivery to a real inbox,
  provider ID,mail-tester>=9,bounce path proven.
- P6.02: first-real-payment record CLOSED: live acct_/ch_/re_ IDs,live decline,
  live refund,zero-drift reconciliation; GATES.md also requires real provider
  enabled,completed booking,payout,Stripe screenshot. Do not fabricate a decline.
- P6.03: Trainer AND club production journey with real data,timestamps/screenshots:
  signup ->door ->website ->confirm ->roster ->Stripe ->Gmail ->billing draft ->
  overnight agent ->next-morning queue ->approve reminder ->email ->parent pays ->
  ledger ->reconciliation ->Free wall ->upgrade ->wall clears.
- P6.04: Error tracking client/api/every edge function; test error lands.
- P6.05: Uptime for sporv.ai and two edge functions,actual phone alert.
- P6.06: cron-http-health and production-invariants green72hours, actual history.
- P6.07: Every cron logs start/end/rows/errors; seven days queryable.
- P6.08: Last-good deployment tagged; Vercel AND Supabase rollback rehearsed.
- P6.09: Runbook for Resend outage,Stripe webhook lag,cron failure,wrong charge.
- P6.10: Privacy names Google scopes,minors,retention,deletion; Google verification
  submitted; real Terms,subscription-refund policy,Contact.
- P6.11: Book-a-call real slots,confirmation,pre-call org/website/roster form.
- P6.12: Monitored support,stated response time,status/outage communication.
- P6.13: Three real first-time onboarding runs,recorded median<20minutes.
- P6.14: Every marketed feature maps to inventory4+; out-of-scope builder/live
  scoring/POS/tee-time exclusions explicit; banned-words grep zero; real-org hero.
- P6.15: Five named prospects with contacts,exports obtained/requested,two calls booked.
  Keep private contact data in an appropriate private artifact, not this public repo.
- P6.16: Final evidence record lists every failure,why,fix ETA or authorized
  shipping rationale; no unknown check becomes green. COMPLETE.md only after
  actual final disposition under STATE rules; parked never means launch ready.

Commit intent: final readiness counts with blockers listed; say both gates
closed only if real evidence supports it.
