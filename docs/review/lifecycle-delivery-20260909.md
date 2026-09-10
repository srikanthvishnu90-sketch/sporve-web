# Lifecycle delivery review — September 9, 2026

G4 supporting implementation, **not a passed launch gate**. No real email was
sent during this work. This runtime review is held from deployment and is
separate from the SQL-only PR399.

## Changes in the actual worker

- Claimed guardians use the previously staged delivery-only inbox RPC. It
  requires an existing human approval and commits quota/notification/receipt
  together. The worker verifies the receipt before counting delivery or pushing.
- External email claims now bind the exact organization, owner approval,
  approval time, content and unsent state. A failed or no-op claim cannot grant
  permission to contact the provider.
- An email-provider success now counts only after the saved database row is
  returned and matches its provider message id, sent time, original approval,
  organization, content, status and cleared error. No-op/mismatched receipt
  writes return503 and cannot reset an accepted request for a blind resend.
- Provider calls have a10-second deadline, an8192-byte response cap and reject
  redirects. A timeout, malformed success, conflict or ambiguous server failure
  produces a checked needs-review state, not another automatic provider request.
- A429 produces a checked delayed retry with exponential backoff and respects
  Retry-After. Definite request rejection produces a sanitized review reason.
- Provider identity and reply-setting outages cannot silently invent fallback
  successful reads. Guardian unsubscribe-signing failure stops before claiming.
- One organization's unverified delivery does not stop another organization's
  independent verified delivery. The batch returns503 if any result is uncertain.
- Receipt comparison accepts equivalent PostgreSQL/JavaScript timestamp
  formatting but preserves microsecond precision; a changed approval instant
  cannot pass just because JavaScript rounds both values to one millisecond.

The worker still requires a human approval. It does not create approval,
auto-send preferences, charges, refunds, or a new AI tool. Policy-file edits
are concrete TypeScript annotations needed for the real SDK type-check.

## Pasted local evidence

```text
node --test --test-name-pattern='email provider acceptance|uncertain email transport|email provider has' supabase/functions/lifecycle-process/security.test.mjs
before: tests5 pass0 fail5 exit1
The old worker returned200 when sent-state writes failed and after uncertain transport.

node --test supabase/functions/lifecycle-process/security.test.mjs
after: tests222 pass222 fail0 exit0
Combined14-file billing/security regression: tests455 pass455 fail0 exit0

Timestamp-format regression before normalization: tests1 pass0 fail1 exit1
Equivalent +00:00/six-digit response incorrectly returned503 instead of200.
After: equivalent timestamp formatting passes; changed microseconds fail closed.

deno check --no-config --node-modules-dir=none --cached-only supabase/functions/lifecycle-process/index.ts
exit0
git diff --check: exit0
bash src/smoke.sh: exit1 after successful build/source contracts
Chromium startup: SIGTRAP / kill EPERM; browser assertions did not run locally.
```

These Node tests execute the actual handler with database/provider doubles.
They are not evidence of live delivery, production RLS or whole-system
exactly-once behavior. The SQL and genuine concurrent-session evidence for the
inbox RPC is in `sql-fixtures-20260909.md` and PR399.

## Conditions before any runtime deployment

1. Independently review and apply the coordinated SQL prerequisites from PR399
   before switching this inbox caller. No migration is applied by this PR.
2. Historical status before the September10 integration: email shared-quota integration was incomplete. See the dated update below; The email worker does
   not yet call the sealed dispatch/reservation protocol; approval-time quota
   is not enough. Current receipt checks harden the existing path, not replace
   that protocol or prove Free's monthly send cap end to end.
3. A durable immutable email attempt/payload, provider idempotency key and
   provider/webhook reconciliation are still required. Accepted-provider / lost
   database-receipt cases intentionally hold the processing claim; there is no
   automatic recovery yet. Operators must not blindly reset those rows.
4. The new SQL recheck in PR399 blocks old-month reservations until they are
   reconciled; it does not implement automatic quota transfer/release. The
   existing pool cannot prove whether a reserved email was accepted externally.
5. Historical status before the September10 integration: direct-email drafts without a guardian retained their existing behavior and
   lack a guardian unsubscribe token. Complete direct-recipient opt-out and
   entitlement-driven branding before calling the delivery gate closed.
6. Real admin-role authorization, production schema compatibility, full browser
   journeys, a real inbox/message-id/bounce/mail-tester run and reviewed release
   remain required. No changes here are declared production-ready on test count.

Provider contracts checked against [Resend errors](https://resend.com/docs/api-reference/errors)
and [Resend idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys).
Resend's24-hour idempotency retention is why a late retry needs a durable
payload and reconciliation; the current worker must not claim exactly-once.

## September 10: sealed email caller integration (review draft)

This dated section supersedes the legacy direct-update description above.
The actual email caller now uses `prepare_approved_lifecycle_email` from PR399
before any provider request and `record_lifecycle_email_result` afterward.
Preparation validates the human approval, current guardian and shared quota,
then returns the exact persisted wire bytes, SHA256, idempotency key and attempt.
The worker validates both the hash and every envelope field against the
requested recipient/body, sends the returned string unchanged, and counts
acceptance only after validating the immutable result transaction receipt.

- Free branding comes from the receipt's entitlement value. Paid mail does not
  carry an unconditional "via Sporv" display name.
- Held, deferred and already-accepted dispatches never authorize a provider call.
  Stale idempotency windows fail closed; ambiguous acceptance never resets to
  approved. No independent email sent-state UPDATE remains in this worker.
- Quota denials appear explicitly in the cron's per-message `quotaDenials`
  with the standard five-field payload. This authenticated batch endpoint keeps
  processing other orgs; it is not the human send endpoint's HTTP402 proof.
- The SQL contract requires a verified guardian. Direct-recipient-only drafts
  now remain visible in needs_review with
  `verified_guardian_required_for_email`; that delivery path is an OPEN
  blocker, not deleted or presented as working.
- SQL and caller must be independently reviewed and deployed together. PR399
  does not apply its drafts, and this draft PR does not deploy an edge function.
- Provider/webhook reconciliation, expired reservation handling, definite
  rejection quota release, distinct-admin authorization and live
  inbox/bounce/mail-tester acceptance remain OPEN.
- Local shell is unavailable in this session. The owner authorized isolated
  GitHub draft-PR edits and CI, with PR comments replacing local Clo hooks.
  This is not evidence that uncommitted local work was inspected or released.

### Before-fix evidence: actual worker, not a surrogate

Commit: d3f7d87d0deec16bbb14e6c063d34ed74a226bf8.
[PR checks run](https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34506505166),
security job102969890767:

```text
2026-09-10T17:10:27.4975266Z tests 224
2026-09-10T17:10:27.4975998Z pass 223
2026-09-10T17:10:27.4976254Z fail 1
2026-09-10T17:10:27.4980355Z AssertionError: the actual email handler must call the atomic prepare RPC
2026-09-10T17:10:27.5034068Z Process completed with exit code 1
```

Browser smoke job102969891112 passed on that red regression commit.
After-fix CI is required; syntax parsing alone is not test execution.
No prompt or business gate is declared complete by this integration.
