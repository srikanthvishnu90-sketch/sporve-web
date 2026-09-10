# Sporv launch state

Updated:2026-09-10
Active: Prompt1 / P1.01
Progress:0/69 verified;0 parked;0/6 prompts DONE.
Business-gate verdict: NOTHING MOVED; tracker setup is governance.

## Execution contract

This file alone records progress. PROMPTS.md records recovered requirements;
CONTEXT.md supplies later product/pricing/design overrides. Read STATE first
every session. Work one criterion, run its actual check, commit evidence,
then update the checkbox and NEXT.

[x] means VERIFIED with actual evidence, not merely written or tested in a
double. [ ] means not accepted. PARKED is explicitly non-green and must carry
failure evidence, reason, dependency and resume condition. Never park work
merely because implementation is hard; exhaust safe in-scope work first.
No prompt is DONE until its criteria pass. The truncated parking/DONE conflict
is recorded in docs/decisions/constitution-adoption-20260909.md.

Source branch: codex/launch-driver-20260910, PR412.
GitHub draft branches/PR comments are the owner-approved remote workflow.
Critical-path review/release rules remain. Production reads do not authorize
writes; fixtures never run against production.

## Prompt status

| Prompt | Status | Verified / total |
| --- | --- | --- |
| 1 | IN PROGRESS | 0 / 11 |
| 2 | NOT DONE | 0 / 7 |
| 3 | NOT DONE | 0 / 4 |
| 4 | NOT DONE | 0 / 25 |
| 5 | NOT DONE | 0 / 6 |
| 6 | NOT DONE | 0 / 16 |

## Prompt1 acceptance

- [ ] P1.01: Exactly3 seeded live plan_entitlements rows; every required field populated.
- [ ] P1.02: Plan/plan_key string-equality comparison grep returns zero in src/,api/,supabase/.
- [ ] P1.03: Free16th member ->402 upgrade_to Solo; Gmail connect ->402; draft21 behavior and finding proven against the explicitly resolved specification; Ask26 ->402. All other listed server gates also tested with exact payloads.
- [ ] P1.04: Solo Outlook ->402; Gmail connection succeeds.
- [ ] P1.05: Organization permits entitled actions within its purchased capacity; no decorative cap or accidental paid send limit. This supersedes the old unlimited Enterprise plan definition, not the requirement for enforcement.
- [ ] P1.06: Stripe test subscription/relevant cancellation changes entitlements within60seconds; failed payment preserves access through dunning and then Free; period-end cancellation timing follows the later constitution.
- [ ] P1.07: Customer Portal opens and a real test-mode card change succeeds.
- [ ] P1.08: Organization ->Free with200 members preserves reads/export/dues, prevents new members with402 and deletes nothing.
- [ ] P1.09: Billing and Connect share no table/handler/function; grep plus review proves old subscription handling is removed from the dues path.
- [ ] P1.10: Pricing shows Free and exactly two paid cards, Solo/Organization; correct centralized prices, annual wording, no camp charge or club tier.
- [ ] P1.11: The remaining requirements above, including trial, branding, data-driven caps, add-ons/metering and safe concurrent enforcement, have implementation and acceptance evidence, not only the ten headline cases.

## Prompt2 acceptance

- [ ] P2.01: Trainer table covers every listed feature with all evidence columns.
- [ ] P2.02: Team table covers every listed feature with all evidence columns.
- [ ] P2.03: Gym table covers every listed feature with all evidence columns.
- [ ] P2.04: Complete cross-cutting inventory,30 agent jobs and20 Ask features.
- [ ] P2.05: Five evidence-backed workflows for each of nine replacement products.
- [ ] P2.06: SELLABLE TODAY (4–5,end-to-end), BLOCKS A SEGMENT (absent/<=2,ranked by customers blocked), CLAIMED BUT NOT REAL (UI and commit discrepancies).
- [ ] P2.07: Each segment ends yes/no/only-if-X; completed inventory committed, no feature edits included in this audit. Zero claimed-but-not-real remains a launch gate, not a reason to suppress findings.

## Prompt3 acceptance

- [ ] P3.01: Every in-scope inventory feature at4+ with definition-of-done evidence; exclusions explicit on the marketing site, never silently removed.
- [ ] P3.02: Five EXPLAIN ANALYZE outputs and ledger latency target evidence.
- [ ] P3.03: docs/review/scale-test.md records full5000-org load, wall time, connections,cost, batching/recovery, send-window/capacity verdict.
- [ ] P3.04: Two concurrent approvals ->one send; import during cron ->no duplicate members; duplicate Stripe webhook ->one ledger entry; mid-cron downgrade enforced on next chunk. Each has a passing actual concurrency test.

## Prompt4 acceptance

- [ ] P4.01: Every public table has RLS; query rowsecurity=false returns zero.
- [ ] P4.02: OrgA owner cannot read OrgB in EVERY org-scoped table, app filters removed.
- [ ] P4.03: Guardian cannot read another family's members,installments,ledger, signatures or notes.
- [ ] P4.04: Staff money/eligibility/settings writes ->403 with valid API tokens.
- [ ] P4.05: Findings,drafts and Ask cannot cite another org; similar-data fixture proves it.
- [ ] P4.06: DOB,emergency contacts,medical notes only guardians/admins; staff query ->null.
- [ ] P4.07: Retention/deletion policy written and mechanically enforced.
- [ ] P4.08: Complete member export proven against schema, not a partial bundle.
- [ ] P4.09: Secret scan in src/,api/,supabase/functions/,vercel.json and browser bundle; no embedded keys or browser service-role access. Literal provider-key patterns/environment-variable-name matches reported honestly, not suppressed.
- [ ] P4.10: Secrets held only in approved secret stores; rotation procedure documented.
- [ ] P4.11: No agent-controlled path grants approval, sends, charges or refunds; draft-first trigger enabled and attempted bypass denied. The literal blanket prohibition on even human-authorized delivery adapters is a recorded conflict.
- [ ] P4.12: 25 hostile inputs via Ask,website,email cannot cause unauthorized send, non-confirmed writes,cross-org reads or fabricated facts; nightly CI execution.
- [ ] P4.13: SSRF rejects internal/mixed IPs,off-domain redirects,oversize,slow-loris.
- [ ] P4.14: Stripe,Billing,Resend unsigned webhook requests ->401; replay idempotent.
- [ ] P4.15: Every unauthenticated auth/signup/extraction/Ask limit actually triggers.
- [ ] P4.16: Every authenticated money/send endpoint rate limit actually triggers.
- [ ] P4.17: Magic link<=15min,single-use; refresh rotates; sign-out revokes server-side.
- [ ] P4.18: Password minimum12 client AND server.
- [ ] P4.19: Google login mode cannot silently create an account.
- [ ] P4.20: Unknown/known email sign-in responses and timing avoid enumeration.
- [ ] P4.21: Live sporv.ai CSP,HSTS,X-Frame-Options DENY,Referrer-Policy; paste headers.
- [ ] P4.22: npm audit zero high/critical; dependency/edge versions pinned.
- [ ] P4.23: Supabase PITR enabled; actual restore to branch dated and verified.
- [ ] P4.24: All Prompt1 gates retested directly with valid API tokens and exact402.
- [ ] P4.25: Audit committed with check counts, evidence, every open finding; no unlisted security risk or fake live proof.

## Prompt5 acceptance

- [ ] P5.01: Free25 drafts ->20 sendable and5 visible marked over-limit, after the quota-policy conflict is explicitly resolved.
- [ ] P5.02: All four walls have correct contextual copy,plan and working button.
- [ ] P5.03: Upgrade from blocked action completes it safely without redoing it.
- [ ] P5.04: Days11/13/14 findings fire with real counts.
- [ ] P5.05: Cancel preserves paid-period access then Free; reason is stored.
- [ ] P5.06: Billing UI live usage matches SQL; portal/card/invoices work; visibility thresholds,locked surfaces,trial banner and required instrumentation verified.

## Prompt6 acceptance

- [ ] P6.01: docs/gates/delivery-live.md: real mail.sporv.ai delivery to a real inbox, provider ID,mail-tester>=9,bounce path proven.
- [ ] P6.02: first-real-payment record CLOSED: live acct_/ch_/re_ IDs,live decline, live refund,zero-drift reconciliation; GATES.md also requires real provider enabled,completed booking,payout,Stripe screenshot. Do not fabricate a decline.
- [ ] P6.03: Trainer AND club production journey with real data,timestamps/screenshots: signup ->door ->website ->confirm ->roster ->Stripe ->Gmail ->billing draft -> overnight agent ->next-morning queue ->approve reminder ->email ->parent pays -> ledger ->reconciliation ->Free wall ->upgrade ->wall clears.
- [ ] P6.04: Error tracking client/api/every edge function; test error lands.
- [ ] P6.05: Uptime for sporv.ai and two edge functions,actual phone alert.
- [ ] P6.06: cron-http-health and production-invariants green72hours, actual history.
- [ ] P6.07: Every cron logs start/end/rows/errors; seven days queryable.
- [ ] P6.08: Last-good deployment tagged; Vercel AND Supabase rollback rehearsed.
- [ ] P6.09: Runbook for Resend outage,Stripe webhook lag,cron failure,wrong charge.
- [ ] P6.10: Privacy names Google scopes,minors,retention,deletion; Google verification submitted; real Terms,subscription-refund policy,Contact.
- [ ] P6.11: Book-a-call real slots,confirmation,pre-call org/website/roster form.
- [ ] P6.12: Monitored support,stated response time,status/outage communication.
- [ ] P6.13: Three real first-time onboarding runs,recorded median<20minutes.
- [ ] P6.14: Every marketed feature maps to inventory4+; out-of-scope builder/live scoring/POS/tee-time exclusions explicit; banned-words grep zero; real-org hero.
- [ ] P6.15: Five named prospects with contacts,exports obtained/requested,two calls booked. Keep private contact data in an appropriate private artifact, not this public repo.
- [ ] P6.16: Final evidence record lists every failure,why,fix ETA or authorized shipping rationale; no unknown check becomes green. COMPLETE.md only after actual final disposition under STATE rules; parked never means launch ready.

## PARKED

None. Unverified work remains unchecked.

## Evidence log

- INIT01: first STATE.md fetch on main ->GitHub API404 Not Found.
  Bootstrap-only commit3e3aab60aedb1d946e22b5b548765be01015cdb1 created STATE
  before other launch work; no criterion credited.
- INIT02: PROMPTS.md fetch on main ->GitHub API404 Not Found.
  Recovered available owner prompts with constitution overrides; did not invent
  the truncated ending or missing template.
- INIT03: executed structural check:6 prompt sections,69 unique acceptance IDs,
 69 matching unchecked state entries. Tracker structure only, not product proof.

## NEXT

P1.01: inspect live plan_entitlements keys/required fields with a read-only
query; compare the review SQL/fixtures and current callers. Fix missing catalog
behavior in an isolated review branch and execute actual SQL checks. Do not
apply a rename without compatible caller cutover and required review. Prior
fixtures/commits do not automatically pass this live acceptance.
