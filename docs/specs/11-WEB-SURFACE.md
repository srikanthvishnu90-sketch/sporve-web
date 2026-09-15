# 11 — WEB SURFACE (single client, agent-first)
**Gate:** blocks G8, G9. **Current state:** index.html + src/mod-*.js, site.webmanifest present. No service worker, no offline write queue, no role-scoped shell, no realtime subscriptions in app modules.
## 11.1 The decision
One client: a web app at app.sporv.ai, installable, used by coaches/directors/treasurers/registrars. No native app in v1. Parents never enter here (spec 13). Flutter retired — record in docs/decisions/retire-flutter.md and remove refs from PRODUCT.md, CONTEXT.md, readiness docs.
## 11.2 Layout: the agent proposes, the canvas proves
Two regions always visible above 900px. **Canvas (primary):** real org state as inspectable objects (roster, schedule, money, documents, people); every number clickable to source rows. **Agent rail (persistent, right):** Noticed (agent_findings not dismissed) · Drafted (agent_proposals + outbound_messages in draft) · Waiting on you (blocked on a human, with reason). Below 900px the rail is a bottom sheet, never removed. **Invariant:** nothing in the rail sends, charges, or mutates on its own — one human click per action (trg_outbound_freeze, trg_agent_findings_dismiss_only).
## 11.3 Install and notification
site.webmanifest display:standalone, maskable icons, start_url/scope; Lighthouse PWA audit. Explicit "Add Sporv to your home screen" onboarding step (on iOS web push only works after install). Web push for staff after install; time-critical items also go by SMS. Sessions persist ≥90 days with silent refresh. **DoD:** tests/pwa/install-and-push.spec.ts.
## 11.4 Offline at the field
Offline-eligible writes: attendance marking, session cancellation, roster note capture. Service worker Cache-First shell / Network-First data; IndexedDB `pending_writes(id, op, payload, client_ts, attempts)`; every offline write idempotent by client UUID (server upserts on it); conflict rule last-write-wins by server receipt, EXCEPT attendance = append-only (read model = latest per (session_id, athlete_id, marked_by)); persistent "N changes waiting to sync" chip; queue survives tab close + restart. **DoD:** tests/offline/attendance-queue.spec.ts — offline, mark 20, kill tab, reopen, online → exactly 20 server rows, empty queue.
## 11.5 Realtime
Supabase Realtime on sessions, attendance, obligations, agent_findings, outbound_messages; org-scoped, respects RLS. **DoD:** tests/realtime/two-client-schedule.spec.ts.
## 11.6 Roles (organization_members.role) — enforced in RLS, reflected in UI
owner: everything · director: all but platform billing (publish schedule, send drafts, manage roster) · treasurer: money/obligations/ledger/payouts (refunds, adjust, export) · registrar: roster/documents/eligibility/consents (import, approve registrations, waivers) · coach: own teams only (attendance, notes, availability). **DoD:** tests/rls/role-matrix.spec.ts — table-driven (role × table × op), denials as zero rows.
## 11.7 Audit log for the board
Extend settings_audit to: obligation amount changes, refunds, role grants, schedule publication, waiver template changes, every agent send. Read-only Activity view, filter by actor/date, CSV export. **DoD:** tests/audit/coverage.spec.ts — each mutation writes exactly one audit row (actor, before, after).
## 11.8 Performance budget
FCP <1.5s mid-tier Android/4G; schedule interactive <2.5s with 500 athletes/400 sessions; ≤4 round trips per view. **DoD:** tests/perf/budget.spec.ts in CI against a seeded 500-athlete org.
