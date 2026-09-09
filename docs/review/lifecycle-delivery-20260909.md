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

The worker still requires a human approval. It does not create approval,
auto-send preferences, charges, refunds, or a new AI tool. Policy-file edits
are concrete TypeScript annotations needed for the real SDK type-check.

## Pasted local evidence

```text
node --test --test-name-pattern='email provider acceptance|uncertain email transport|email provider has' supabase/functions/lifecycle-process/security.test.mjs
before: tests5 pass0 fail5 exit1
The old worker returned200 when sent-state writes failed and after uncertain transport.

node --test supabase/functions/lifecycle-process/security.test.mjs
after: tests214 pass214 fail0 exit0
Combined14-file billing/security regression: tests447 pass447 fail0 exit0

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
2. Email shared-quota integration is STILL INCOMPLETE. The email worker does
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
5. Direct-email drafts without a guardian retain their existing behavior and
   lack a guardian unsubscribe token. Complete direct-recipient opt-out and
   entitlement-driven branding before calling the delivery gate closed.
6. Real admin-role authorization, production schema compatibility, full browser
   journeys, a real inbox/message-id/bounce/mail-tester run and reviewed release
   remain required. No changes here are declared production-ready on test count.

Provider contracts checked against [Resend errors](https://resend.com/docs/api-reference/errors)
and [Resend idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys).
Resend's24-hour idempotency retention is why a late retry needs a durable
payload and reconciliation; the current worker must not claim exactly-once.
