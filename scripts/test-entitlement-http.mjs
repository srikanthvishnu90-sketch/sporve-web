import assert from "node:assert/strict";
import { createHmac } from "node:crypto";

const origin = "http://127.0.0.1:3007";
const secret = "fixture-only-jwt-secret-with-at-least-32-bytes";
const id = n => "00000000-0000-0000-0000-" + String(n).padStart(12, "0");
const owner = n => "10000000-0000-0000-0000-" + String(n).padStart(12, "0");
function token(sub, signingKey = secret) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString("base64url");
  const value = encode({ alg: "HS256", typ: "JWT" }) + "." +
    encode({ role: "authenticated", sub, exp: Math.floor(Date.now() / 1000) + 600 });
  return value + "." + createHmac("sha256", signingKey).update(value).digest("base64url");
}
async function request(path, sub, body, method = body ? "POST" : "GET", signingKey = secret) {
  const response = await fetch(origin + path, {
    method, redirect: "error", signal: AbortSignal.timeout(8000),
    headers: { Authorization: "Bearer " + token(sub, signingKey), "Content-Type": "application/json", Prefer: "return=representation" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}
function limit(result, reason, upgrade, cap, count) {
  assert.equal(result.status, 402, JSON.stringify(result));
  assert.equal(result.body.code, "PT402");
  const actual = JSON.parse(result.body.details);
  assert.deepEqual(actual, { reason, current_plan: "free", upgrade_to: upgrade, limit: cap, current: count });
  console.log("HTTP402 " + reason + " " + JSON.stringify(actual));
  return actual;
}

const before = await request("/team_athletes?provider_id=eq." + id(1), owner(1));
assert.equal(before.status, 200);
assert.equal(before.body.length, 15);
const capped = await request("/team_athletes", owner(1), { provider_id: id(1), first_name: "api-sixteen" });
limit(capped, "member_cap", "solo", 15, 15);
assert.equal((await request("/team_athletes?provider_id=eq." + id(1), owner(1))).body.length, 15);
console.log("PASS valid owner JWT: sixteenth member HTTP402; stored member count stays15");

limit(await request("/teams", owner(1), { provider_id: id(1), name: "api-second" }), "group_cap", "solo", 1, 1);
limit(await request("/organization_members", owner(1), {
  organization_id: id(1), member_user_id: owner(8), role: "admin",
}), "admin_cap", "organization", 1, 1);

for (const [table, column] of [["team_athletes", "provider_id"], ["teams", "provider_id"], ["organization_members", "organization_id"]]) {
  const result = await request("/" + table + "?" + column + "=eq." + id(3), owner(1));
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, []);
}
const crossWrite = await request("/team_athletes", owner(1), { provider_id: id(3), first_name: "cross-org" });
assert.equal(crossWrite.status, 403, JSON.stringify(crossWrite));
assert.doesNotMatch(JSON.stringify(crossWrite.body), /member_cap|current_plan|upgrade_to/);
console.log("PASS owner JWT: three fixture table cross-org reads empty; cross-org insert403 without entitlement leakage");

const staff = await request("/teams", "20000000-0000-0000-0000-000000000002", { provider_id: id(1), name: "staff-group" });
assert.equal(staff.status, 403);
const invalid = await request("/team_athletes", owner(1), undefined, "GET", "wrong-fixture-signing-key");
assert.equal(invalid.status, 401);
console.log("PASS real JWT validation: invalid signature401; staff write403");

const [one, two] = await Promise.all([
  request("/team_athletes", owner(4), { provider_id: id(4), first_name: "parallel-one" }),
  request("/team_athletes", owner(4), { provider_id: id(4), first_name: "parallel-two" }),
]);
assert.deepEqual([one.status, two.status].sort(), [201, 402]);
assert.equal((await request("/team_athletes?provider_id=eq." + id(4), owner(4))).body.length, 15);
console.log("PASS two real HTTP requests for the final member slot: one201, one402, total15");

const separate = await request("/team_athletes", owner(2), { provider_id: id(2), first_name: "independent" });
assert.equal(separate.status, 201);
console.log("PASS capped Free organization does not block another owner's entitled insert");

// Do not hide PostgREST's standard error envelope. This proves a database
// status and fields inside details, NOT the requested top-level app payload.
assert.equal(capped.body.reason, undefined);
console.log("KNOWN GAP: raw table endpoint wraps reason/current_plan/upgrade_to/limit/current in details; application endpoint top-level payload is not proven");
console.log("SUPPORTING PASS: actual guard SQL + JWT HTTP + fixture-only owner RLS; not production or full P1.03 acceptance");
