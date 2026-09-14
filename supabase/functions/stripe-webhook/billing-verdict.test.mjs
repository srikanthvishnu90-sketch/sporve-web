// Billing-verdict control-flow tests: apply_stripe_billing_event RETURNS text and
// never raises, so `error` is always null. These prove the handler reads the
// VERDICT and never acknowledges a rejected outcome silently. Stripe and the DB
// are isolated doubles; this does not prove signatures, SQL, RLS or live money.
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { webcrypto } from 'node:crypto';
import vm from 'node:vm';
import { HttpInputError, readBoundedText, withHttpDeadline } from '../_shared/http.ts';

const source = stripTypeScriptTypes((await readFile(new URL('./index.ts', import.meta.url), 'utf8'))
  .replace(/^import\s+[\s\S]*?;\n/gm, ''));

function subscriptionEvent(plan = 'pro', status = 'active') {
  return { id: 'evt_billing_fixture', type: 'customer.subscription.updated', livemode: false, created: 1788976800,
    data: { object: { id: 'sub_fixture', object: 'subscription', status, cancel_at_period_end: false,
      current_period_start: 1788976800, current_period_end: 1791568800,
      metadata: { provider_id: '30000000-0000-4000-8000-000000000001', plan },
      items: { data: [{ price: { id: 'price_fixture', unit_amount: 3499, currency: 'usd' } }] } } } };
}

async function invoke({ verdict, deadLetterThrows = false } = {}) {
  const event = subscriptionEvent();
  const payload = JSON.stringify(event);
  const calls = [];
  let handler;
  const admin = {
    async rpc(name, args) {
      calls.push({ name, args });
      if (name === 'record_webhook_dead_letter') {
        if (deadLetterThrows) throw new Error('dead-letter store unavailable');
        return { data: null, error: null };
      }
      assert.equal(name, 'apply_stripe_billing_event');
      return { data: verdict, error: null };
    },
    from() { throw new Error('billing path must not read tables when provider_id rides on metadata'); },
  };
  class StripeFixture {
    static createFetchHttpClient() { return {}; }
    static createSubtleCryptoProvider() { return {}; }
    webhooks = { constructEventAsync: async () => event };
  }
  vm.runInNewContext(source, { Stripe: StripeFixture, createClient: () => admin,
    Response, TextEncoder, crypto: webcrypto, console: { error() {} },
    HttpInputError, readBoundedText,
    withHttpDeadline: (work, ms) => withHttpDeadline(work, Math.min(ms, 50)),
    Deno: { serve(fn) { handler = fn; }, env: { get: key => ({
      STRIPE_SECRET_KEY: 'test-mode-fixture', STRIPE_WEBHOOK_SECRET: 'signature-fixture',
      SUPABASE_URL: 'https://fixture.invalid', SUPABASE_SERVICE_ROLE_KEY: 'server-fixture',
    })[key] } } });
  const response = await handler(new Request('https://fixture.invalid/stripe-webhook', {
    method: 'POST', headers: { 'stripe-signature': 'fixture-signature' }, body: payload }));
  return { status: response.status, body: await response.text(), calls,
    deadLettered: calls.some(c => c.name === 'record_webhook_dead_letter') };
}

// ── success family: a 200 with NO dead letter is correct ─────────────────────
for (const verdict of ['applied:pro/active', 'duplicate', 'stale']) {
  test(`${verdict} acknowledges with 200 and no dead letter`, async () => {
    const r = await invoke({ verdict });
    assert.equal(r.status, 200);
    assert.equal(r.deadLettered, false);
  });
}

// ── REJECTED family: a SILENT 200 is the bug. Each must leave a durable,
//    queryable dead-letter record. (Design: retry is futile because the ledger
//    already recorded the event, so 5xx-forever buys nothing — but a 200 with no
//    record is exactly what let a paid org get nothing.) ──────────────────────
for (const verdict of ['ignored_bad_plan:solo', 'ignored_unknown_status:paused', 'provider_not_found']) {
  test(`${verdict} is NEVER a silent 200 — it must be dead-lettered`, async () => {
    const r = await invoke({ verdict });
    assert.ok(r.deadLettered, `expected record_webhook_dead_letter for ${verdict}; status=${r.status}`);
    const dl = r.calls.find(c => c.name === 'record_webhook_dead_letter');
    assert.ok(String(dl.args.p_error).includes(verdict.split(':')[0]), 'dead letter must carry the verdict');
  });
}
test('provider_not_found is flagged CRITICAL in the dead letter (a payment for a nonexistent org)', async () => {
  const r = await invoke({ verdict: 'provider_not_found' });
  const dl = r.calls.find(c => c.name === 'record_webhook_dead_letter');
  assert.ok(dl && /CRITICAL/.test(String(dl.args.p_error)));
});

// ── an UNRECOGNIZED verdict must be treated as REJECTED, never as success ────
for (const verdict of ['applied', 'ok', 'success', '', null, undefined, 42, true, {}, 'applied_later:pro']) {
  test(`unrecognized verdict ${JSON.stringify(verdict)} is not acknowledged as success`, async () => {
    const r = await invoke({ verdict });
    assert.ok(r.deadLettered || r.status >= 500, `silent 200 for ${JSON.stringify(verdict)}`);
  });
}

// ── if the dead-letter write itself fails there is no durable record, so the
//    only honest answer is 5xx (Stripe retries; nothing is swallowed) ─────────
test('REJECTED with a failing dead-letter store returns 5xx, never 200', async () => {
  const r = await invoke({ verdict: 'ignored_bad_plan:solo', deadLetterThrows: true });
  assert.ok(r.status >= 500, `got ${r.status}`);
});
