import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../src/mod-coachaccount.js", import.meta.url), "utf8");
const row = (patch = {}) => ({
  plan: "renamed-plan", display_name: "A catalog label", price_usd_month: 49,
  purchasable: true, ask_quota_month: 17, admin_cap: 2, ...patch,
});
function fixture(initialRows = []) {
  let rows = initialRows, failure = false, calls = [], buttons = [];
  const ui = {
    activeTab: (_tabs, initial) => initial,
    Button: (button) => { buttons.push(button); return button.label; },
    EmptyState: (title, message) => title + ": " + message,
    ListCard: (items) => JSON.stringify(items),
    Block: ({ title, body }) => title + body,
    Page: ({ body }) => body,
    html: (value) => value,
  };
  const window = {
    location: { origin: "https://sporv.ai", pathname: "/", href: "" },
    COACH_UI: ui,
    SporveAuth: { userId: () => "owner-a" },
    SporveAPI: {
      from: async () => { if (failure) throw new Error("private database detail"); return rows; },
      fn: async (kind, body) => { calls.push({ kind, body }); return { checkoutUrl: "https://checkout.stripe.com/fixture" }; },
    },
  };
  vm.runInNewContext(source, { window, console, esc: value => String(value).replace(/[<>&"]/g, "_") });
  return {
    account: window.SporveCoach, view: () => window.MOD_COACHBILLING.views.billing(), calls, buttons,
    setRows(next) { rows = next; }, fail() { failure = true; },
  };
}
test("before loading, no invented plan price or quota is exposed", () => {
  const h = fixture();
  assert.deepEqual(Object.keys(h.account.plans()), []);
  assert.match(h.view(), /Loading plan details/);
  assert.doesNotMatch(h.view(), /34\.99|Unlimited AI|Three AI/);
});
test("arbitrary catalog keys produce their own labels, price, quotas and seats", async () => {
  const h = fixture([row(), row({ plan: "no-card", display_name: "No card", price_usd_month: 0, purchasable: false })]);
  await h.account.refreshPlans();
  const p = h.account.plans()["renamed-plan"];
  assert.equal(p.name, "A catalog label");
  assert.equal(p.price, "$49");
  assert.match(p.adds, /17 Ask messages a month, 2 admin seats/);
  assert.equal(p.buyable, true);
  assert.equal(h.account.plans()["no-card"].requiresPayment, false);
  assert.match(h.view(), /A catalog label/);
});
test("legacy rows render actual limits rather than unlimited copy chosen by name", async () => {
  const h = fixture([{ plan: "pro", price_usd_month: 12, purchasable: true, ai_monthly_quota: 9, seat_limit: 1 }]);
  await h.account.refreshPlans();
  assert.match(h.account.plans().pro.adds, /9 Ask messages a month, 1 admin seat/);
  assert.equal(h.account.plans().pro.name, "pro");
});
test("only explicit unlimited values display unlimited counts", async () => {
  const h = fixture([row({ ask_quota_month: -1, admin_cap: null })]);
  await h.account.refreshPlans();
  assert.match(h.account.plans()["renamed-plan"].adds, /without a monthly limit, unlimited admin seats/);
});
test("malformed or empty catalogs produce a visible error and no purchasable fallback", async () => {
  for (const rows of [[], [row({ purchasable: "false" })], [row({ price_usd_month: "" })],
    [row({ ask_quota_month: undefined })], [row(), row()]]) {
    const h = fixture(rows);
    await assert.rejects(h.account.refreshPlans(), /could not be loaded/);
    assert.deepEqual(Object.keys(h.account.plans()), []);
    assert.match(h.view(), /Plan details unavailable/);
    assert.match(h.view(), /Retry plan details/);
    assert.equal(h.calls.length, 0);
  }
});
test("failed reload removes stale purchase choices and hides raw database errors", async () => {
  const h = fixture([row()]);
  await h.account.refreshPlans();
  h.fail();
  await assert.rejects(h.account.refreshPlans(), /could not be loaded/);
  assert.deepEqual(Object.keys(h.account.plans()), []);
  assert.doesNotMatch(h.view(), /private database detail/);
});
test("checkout rechecks catalog eligibility and forwards the selected key only", async () => {
  const h = fixture([row()]);
  await h.account.refreshPlans();
  await h.account.startCheckout("renamed-plan");
  assert.equal(h.calls.length, 1);
  assert.equal(h.calls[0].body.plan, "renamed-plan");
  assert.deepEqual(Object.keys(h.calls[0].body).sort(), ["cancelUrl", "plan", "successUrl"]);
  h.setRows([row({ purchasable: false })]);
  await assert.rejects(h.account.startCheckout("renamed-plan"), /not available for purchase/);
  assert.equal(h.calls.length, 1);
});
test("zero-price selection never opens checkout, regardless of key", async () => {
  const h = fixture([row({ price_usd_month: 0 })]);
  await assert.rejects(h.account.startCheckout("renamed-plan"), /not available for purchase/);
  assert.equal(h.calls.length, 0);
});

test("multiple catalog choices retain one primary action", async () => {
  const h = fixture([row(), row({ plan: "another-paid-plan", price_usd_month: 199 })]);
  await h.account.refreshPlans();
  h.view();
  assert.equal(h.buttons.filter(button => button.attrs?.startsWith("data-cb-buy=")).length, 2);
  assert.equal(h.buttons.filter(button => button.variant === "primary").length, 1);
});

const onboardSource = readFileSync(new URL("../src/mod-coachonboard.js", import.meta.url), "utf8");
function submittedPlan(plan) {
  const window = { SporveCoach: { plans: () => ({ "catalog-paid": plan }) } };
  const S = { onboard: { plan: "catalog-paid", businessName: "Fixture", submittedAt: "2026-09-10T00:00:00Z" } };
  vm.runInNewContext(onboardSource, { window, S, esc: String });
  return { html: window.MOD_COACHONBOARD.views.onboard(), selection: S.onboard.plan };
}
test("submitted persisted unavailable paid plan has no checkout button and says unavailable", () => {
  const result = submittedPlan({ id: "catalog-paid", name: "Fixture paid", requiresPayment: true, buyable: false, price: "$49", per: "/mo" });
  assert.doesNotMatch(result.html, /data-cob-buyplan=/);
  assert.match(result.html, /Fixture paid — unavailable/);
  assert.equal(result.selection, "catalog-paid");
});
test("submitted buyable paid plan keeps its catalog-named checkout action", () => {
  const result = submittedPlan({ id: "catalog-paid", name: "Fixture paid", requiresPayment: true, buyable: true, price: "$49", per: "/mo" });
  assert.match(result.html, /data-cob-buyplan="catalog-paid"/);
  assert.match(result.html, /Start Fixture paid/);
});
