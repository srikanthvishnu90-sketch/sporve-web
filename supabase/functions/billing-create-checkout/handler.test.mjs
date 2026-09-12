import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import vm from "node:vm";

const entry = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
function setup(row, options = {}) {
  const calls = [];
  let handler;
  const provider = { id: "provider-a", business_name: "Fixture club", stripe_customer_id: "cus_fixture", founding_coach: false, plan: "previous", plan_status: "none" };
  const stripe = {
    customers: { retrieve: async () => ({ id: "cus_fixture" }) },
    checkout: { sessions: { create: async (body) => { calls.push(body); return { id: "cs_fixture", url: "https://checkout.stripe.com/fixture" }; } } },
  };
  class Stripe { constructor() { return stripe; } static createFetchHttpClient() { return {}; } }
  const admin = {
    rpc: async () => ({ data: true, error: null }),
    from(table) {
      return {
        select() { return this; },
        eq() { return this; },
        async maybeSingle() {
          return table === "providers" ? { data: provider, error: null }
            : { data: row, error: options.lookupError || null };
        },
      };
    },
  };
  const ctx = vm.createContext({
    Stripe, Request, Response, URL, console: { error() {} },
    createClient: (_url, key) => key === "fixture-anon"
      ? { auth: { getUser: async () => ({ data: { user: { id: "owner-a", email: "owner@example.invalid" } }, error: null }) } }
      : admin,
    Deno: {
      env: { get: (name) => ({
        SUPABASE_URL: "https://project.example.invalid",
        SUPABASE_ANON_KEY: "fixture-anon",
        CHECKOUT_ORIGINS: "https://sporv.ai",
      })[name] || "fixture-server-credential" },
      serve(fn) { handler = fn; },
    },
  });
  const code = entry.replace(/^import Stripe from .*;\n/m, "")
    .replace(/^import \{ createClient \} from .*;\n/m, "");
  vm.runInContext(stripTypeScriptTypes(code), ctx);
  return {
    calls,
    async request(plan = "renamed-plan") {
      const response = await handler(new Request("https://edge.example.invalid/billing-create-checkout", {
        method: "POST", headers: { Authorization: "Bearer fixture-owner", "Content-Type": "application/json" },
        body: JSON.stringify({ plan, successUrl: "https://sporv.ai/?billing=done", cancelUrl: "https://sporv.ai/?billing=cancelled" }),
      }));
      return { status: response.status, body: await response.json() };
    },
  };
}
const catalog = (patch = {}) => ({
  plan: "renamed-plan", display_name: "Catalog-named plan",
  purchasable: true, price_usd_month: 49, ...patch,
});

test("checkout uses catalog label and amount for an arbitrary plan key", async () => {
  const h = setup(catalog());
  assert.equal((await h.request()).status, 200);
  assert.equal(h.calls.length, 1);
  const item = h.calls[0].line_items[0].price_data;
  assert.equal(item.product_data.name, "Catalog-named plan");
  assert.equal(item.unit_amount, 4900);
  assert.equal(h.calls[0].mode, "subscription");
});
test("purchase permission is catalog-driven, not inferred from a key", async () => {
  const h = setup(catalog({ plan: "free" }));
  assert.equal((await h.request("free")).status, 200);
  assert.equal(h.calls.length, 1);
});
test("zero-price and unavailable catalog entries never create Checkout", async () => {
  for (const row of [null, catalog({ purchasable: false }), catalog({ price_usd_month: 0 })]) {
    const h = setup(row);
    const result = await h.request();
    assert.notEqual(result.status, 200);
    assert.equal(h.calls.length, 0);
  }
});
test("malformed purchase permission is rejected", async () => {
  const h = setup(catalog({ purchasable: "false" }));
  assert.equal((await h.request()).status, 409);
  assert.equal(h.calls.length, 0);
});
test("legacy catalog without a label uses its actual key, not a different plan's name", async () => {
  const h = setup(catalog({ display_name: undefined }));
  assert.equal((await h.request()).status, 200);
  assert.equal(h.calls[0].line_items[0].price_data.product_data.name, "renamed-plan");
});
test("catalog lookup failures expose no database error text", async () => {
  const h = setup(null, { lookupError: { message: "private_schema.constraint_name" } });
  const result = await h.request();
  assert.equal(result.status, 503);
  assert.doesNotMatch(JSON.stringify(result.body), /private_schema|constraint_name/);
  assert.equal(h.calls.length, 0);
});
test("invalid plan input is rejected before creating Checkout", async () => {
  for (const value of [null, {}, [], "", "bad/key"]) {
    const h = setup(catalog());
    assert.equal((await h.request(value)).status, 400);
    assert.equal(h.calls.length, 0);
  }
});
