# 16 — COMPLIANCE, ELIGIBILITY, AND MINORS' DATA
**Gate:** G2 and G4. Blocks the first real organization, not just the first sale.
**Current state:** `waiver_documents`, `waiver_signatures`, `staff_certifications`, `guardians`, `guardian_links`, `privacy_requests`, `safety_reports`, `staff-cert-webhook` all exist. `background_check` = 4 matches.
The standing launch blocker is unchanged and is the most serious item in the entire spec set: **a verified badge renders for providers with zero real checks run.**

## 16.1 The badge
Until a real check has been ordered, returned, and recorded, the badge does not render. Not greyed, not "pending" — absent.
This is not a UI change. It is a claim-integrity failure of exactly the kind Gate 2 exists to catch, in the single highest-stakes place it could occur. A club that placed an unchecked adult with children on the strength of your badge is a company-ending event, regardless of what the terms of service say.
**DoD:** `tests/trust/badge-provenance.spec.ts` — asserts the badge component throws rather than renders when its backing check row is absent, and that no code path can pass a literal `true`.

## 16.2 Background checks: real integration
Pick one vendor and integrate it. Candidates: NCSI, Sterling Volunteers, JDP. Selection criteria: youth-sports coverage, continuous monitoring, per-check cost, API quality, and whether the state associations you are targeting already accept that vendor.
```sql
create table if not exists public.background_check (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  member_user_id uuid not null,
  vendor text not null,
  vendor_reference text not null,
  package text not null,
  status text not null check (status in ('ordered','pending','clear','consider','suspended','expired','cancelled')),
  ordered_at timestamptz not null default now(),
  completed_at timestamptz,
  expires_at timestamptz,
  adjudicated_by uuid,
  adjudication_note text,
  unique (vendor, vendor_reference)
);
```
**Rules**
- Sporv stores status and dates only. **Never the report contents.** Criminal history is FCRA-regulated data you have no business holding.
- `consider` results are never auto-adjudicated. A named human at the org decides and the decision is recorded.
- Expiry triggers J5 at 60, 30, and 7 days.
- Who pays is an org setting: org-paid or coach-paid at onboarding.

## 16.3 Certifications
`staff_certifications` exists with `kind`, `status`, `issued_at`, `expires_at`. Populate `kind` with the set that actually gates participation: SafeSport, concussion protocol (state-specific, often annual), CPR/First Aid, sport-specific licences, and state-mandated abuse prevention training.
Eligibility is computed, not stored as a flag:
```
coach is eligible for event E  ⟺
  background_check.status = 'clear' AND not expired
  AND every certification required by E.program is 'valid' AND not expired
```
A coach who becomes ineligible mid-season appears as a finding on every future assigned event. The system records eligibility; it does not order compliance.
**DoD:** `tests/eligibility/coach-gate.spec.ts` — expire one certification and assert every downstream assigned event produces a finding.

## 16.4 Waivers and e-signature enforceability
A signature that will not survive a challenge is worse than no signature, because the club relied on it.
Per signature, record: the **exact document version** signed (content hash, not a foreign key to a mutable row), signer identity, signer IP, user agent, timestamp, and the authentication method that established identity (magic-link token id).
```sql
alter table public.waiver_signatures
  add column if not exists document_sha256 text,
  add column if not exists signer_ip inet,
  add column if not exists signer_user_agent text,
  add column if not exists auth_method text,
  add column if not exists auth_reference uuid;   -- guardian_access_token.id
```
Editing a waiver document creates a new version and invalidates nothing already signed. A club must be able to export, for any athlete, a PDF containing the signed document text plus the evidence record. That export is the artifact a lawyer asks for.
**DoD:** `tests/compliance/waiver-evidence.spec.ts` — signs, mutates the template, and asserts the original signature still resolves to the original text by hash.

## 16.5 Minors' data
- **COPPA.** Under-13 athletes have no direct account. All access is through a linked guardian. There is no path by which a minor authenticates. Assert this in a test, not a policy document.
- **Data minimisation.** Collect birthdate (needed for age-group eligibility), not full date-of-birth-plus-SSN-style identifiers. Medical fields are opt-in per org.
- **Retention.** Default purge of registration answers 24 months after a season closes, configurable upward by the org, with an export first.
- **Deletion.** `privacy_requests` exists. Wire it to an actual cascade that produces a verifiable receipt, and test that the deleted athlete disappears from exports, agent context, and search indexes — not only from the primary table.
- **Agent boundary.** Sensitive fields are excluded from every model context. Test this by asserting the assembled prompt for each job contains no sensitive key.
**DoD:** `tests/privacy/minor-isolation.spec.ts` and `tests/agent/context-redaction.spec.ts`.

## 16.6 Sanctioning bodies: the real replacement blocker
This is the hardest item in the entire set and the one most likely to cap the market regardless of product quality.
State associations, AAU, Little League, USA Hockey and similar bodies require roster and eligibility submission through approved systems, and several sign **exclusive technology provider** agreements covering all member clubs. A club under such an agreement physically cannot leave the incumbent, no matter how good Sporv is.
**v1 approach — do not attempt integration.**
1. **Qualify it in sales.** The first discovery question is: which body sanctions you, and does your registration flow through them? An org with an exclusive arrangement is disqualified for now. Track this on every lead so the real addressable share of the market becomes visible instead of assumed.
2. **Export compatibility.** Produce the roster export formats the common bodies accept, so a registrar can submit manually in minutes. This is unglamorous and it unblocks real deals.
3. **Coexistence.** Support running alongside a sanctioning platform: Sporv is the operating system, the body's system remains the compliance filing surface.
**v2:** pursue one state association partnership directly. That is the only mechanism that replaces an incumbent at scale in this industry, and it is a 12-month sale with a security review attached. Start the relationship now; do not put it on the launch critical path.
**DoD:** a qualification field on every lead record, and one accepted export format per targeted body verified by an actual registrar.

## 16.7 Acceptance for G4
A second organization cannot read a single row belonging to the first, proven by a table-driven cross-tenant suite that asserts zero rows rather than errors. One athlete is fully deleted on request with a receipt. One waiver signature survives a template change. One coach's badge does not render because no check has been run.
