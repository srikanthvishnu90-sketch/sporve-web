import assert from "node:assert/strict";
import { chromium } from "playwright";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { mkdir } from "node:fs/promises";

await mkdir("test-results/plan-catalog", { recursive: true });
const browser = await chromium.launch();
let checks = 0;
try {
  for (const width of [390, 1440]) {
    const page = await browser.newPage({ viewport: { width, height: 900 }, reducedMotion: "reduce" });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.route(/^https?:\/\//, route => route.abort());
    await page.goto(pathToFileURL(resolve("index.html")).href);
    await page.evaluate(async () => {
      const rows = [
        { plan: "free", display_name: "Sporv Free", price_usd_month: 0, purchasable: false, ask_quota_month: 25, admin_cap: 1 },
        { plan: "solo", display_name: "Sporv Solo", price_usd_month: 49, purchasable: true, ask_quota_month: 500, admin_cap: 1 },
        { plan: "organization", display_name: "Sporv Organization", price_usd_month: 199, purchasable: true, ask_quota_month: 2500, admin_cap: 5 },
      ];
      window.SporveAPI.from = async () => rows;
      window.SporveAuth.userId = () => "fixture-owner";
      S.auth = { status: "verified", user: { id: "fixture-owner" } };
      S.portal = "coach";
      await window.SporveCoach.refreshPlans();
      document.getElementById("app").innerHTML = window.MOD_COACHBILLING.views.billing();
    });
    const billing = await page.locator("#app").innerText();
    assert.match(billing, /Sporv Solo/);
    assert.match(billing, /500 Ask messages a month, 1 admin seat/);
    assert.match(billing, /2500 Ask messages a month, 5 admin seats/);
    assert.doesNotMatch(billing, /34\.99|Sporv Pro|Unlimited AI actions/);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true);
    checks += 5;
    await page.screenshot({ path: "test-results/plan-catalog/billing-" + width + ".png", fullPage: true });

    await page.evaluate(() => {
      S.onboard = JSON.parse(JSON.stringify(window.MOD_COACHONBOARD.state.onboard));
      S.onboard.step = 3;
      S.onboard.plan = "solo";
      document.getElementById("app").innerHTML = window.MOD_COACHONBOARD.views.onboard();
    });
    assert.equal(await page.locator("input[data-cob-plan]").count(), 3);
    assert.equal(await page.locator('input[data-cob-plan="solo"]').isChecked(), true);
    assert.equal(await page.locator('input[data-cob-plan="organization"]').isChecked(), false);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true);
    checks += 4;
    await page.screenshot({ path: "test-results/plan-catalog/onboarding-" + width + ".png", fullPage: true });

    await page.evaluate(async () => {
      window.SporveAPI.from = async () => { throw new Error("fixture network failure"); };
      await window.SporveCoach.refreshPlans().catch(() => {});
      document.getElementById("app").innerHTML = window.MOD_COACHBILLING.views.billing();
    });
    assert.match(await page.locator("#app").innerText(), /Plan details unavailable/);
    assert.equal(await page.locator("[data-cb-refresh]").count(), 1);
    assert.equal(await page.locator("[data-cb-buy]").count(), 0);
    assert.equal(errors.length, 0, errors.join("\n"));
    checks += 4;
    await page.screenshot({ path: "test-results/plan-catalog/error-" + width + ".png", fullPage: true });
    console.log("PASS real Chromium at " + width + "px: catalog values, selected onboarding plan, no horizontal scroll, visible error/retry, no JavaScript errors");
    await page.close();
  }
  console.log("PASS " + checks + " DOM assertions; mocked catalog only, no live billing acceptance");
} finally {
  await browser.close();
}
