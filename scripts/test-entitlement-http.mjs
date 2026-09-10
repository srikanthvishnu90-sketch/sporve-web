import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { setTimeout as delay } from "node:timers/promises";

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
    method, redirect: "error", signal: AbortSignal.timeout(12000),
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


// The database controller only coordinates this disposable API's concurrency.
// Customer operations below still execute via signed HTTP, never as postgres.
assert.equal(process.env.PGHOST, "127.0.0.1");
assert.equal(process.env.PGDATABASE, "sporv_entitlement_guard_test");
const exec = promisify(execFile);
const psqlArgs = ["-X", "-qAt", "-v", "ON_ERROR_STOP=1"];
async function psql(sql) {
  const result = await exec("psql", [...psqlArgs, "-c", sql], {
    env: { ...process.env, PGAPPNAME: "sporv_http_observer" },
    timeout: 18000, maxBuffer: 200000,
  });
  return result.stdout.trim();
}
assert.equal(await psql("SELECT current_database()"), "sporv_entitlement_guard_test");
async function hold(sql) {
  const proc = spawn('psql', psqlArgs, {
    env: { ...process.env, PGAPPNAME: 'sporv_http_controller' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let output = '', errors = '';
  proc.stdout.on('data', chunk => { output += chunk; });
  proc.stderr.on('data', chunk => { errors += chunk; });
  const finished = new Promise((resolve, reject) => {
    proc.on('error', reject);
    proc.on('close', code => code === 0 ? resolve() : reject(new Error(`Controller exit ${code}: ${errors}`)));
  });
  // Attach rejection handling before any worker starts; the owner awaits it below.
  finished.catch(() => {});
  proc.stdin.write(`BEGIN; ${sql}; SELECT 'LOCK_READY';\n`);
  const deadline = Date.now() + 8000;
  while (!output.includes('LOCK_READY')) {
    if (proc.exitCode !== null || Date.now() > deadline) {
      proc.stdin.end('ROLLBACK;\n');
      await finished;
      throw new Error(`Controller did not acquire the lock: ${errors}`);
    }
    await delay(20);
  }
  return async (commit = true) => { proc.stdin.end(commit ? 'COMMIT;\n' : 'ROLLBACK;\n'); await finished; };
}

async function waitBlocked() {
  const deadline = Date.now() + 7000;
  while (Date.now() < deadline) {
    const count = Number(await psql(`SELECT count(*) FROM pg_stat_activity
      WHERE datname='sporv_entitlement_guard_test' AND usename='fixture_authenticator'
        AND state='active' AND wait_event_type='Lock' AND wait_event='advisory'`));
    if (count === 2) return;
    await delay(30);
  }
  throw new Error("Did not observe both HTTP inserts waiting on the provider capacity lock");
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

// Hold the actual guard lock until both PostgREST database sessions are
// observed waiting; Promise.all alone would not prove concurrent execution.
const release = await hold(`SELECT pg_advisory_xact_lock(hashtextextended('${id(4)}',41202))`);
const pair = Promise.all([
  request("/team_athletes", owner(4), { provider_id: id(4), first_name: "parallel-one" }),
  request("/team_athletes", owner(4), { provider_id: id(4), first_name: "parallel-two" }),
]);
pair.catch(() => {});
try {
  await waitBlocked();
  const separate = await request("/team_athletes", owner(2), { provider_id: id(2), first_name: "independent" });
  assert.equal(separate.status, 201);
  console.log("PASS other owner's entitled HTTP insert201 while both Free requests are observed blocked");
} finally { await release(); }
const [one, two] = await pair;
assert.deepEqual([one.status, two.status].sort(), [201, 402]);
limit([one,two].find(result => result.status === 402), "member_cap", "solo", 15, 15);
assert.equal((await request("/team_athletes?provider_id=eq." + id(4), owner(4))).body.length, 15);
console.log("PASS two observed concurrent HTTP database sessions: final slot yields one201, one402, total15");

// Do not hide PostgREST's standard error envelope. This proves a database
// status and fields inside details, NOT the requested top-level app payload.
assert.equal(capped.body.reason, undefined);
console.log("KNOWN GAP: raw table endpoint wraps reason/current_plan/upgrade_to/limit/current in details; application endpoint top-level payload is not proven");
console.log("SUPPORTING PASS: actual guard SQL + JWT HTTP + fixture-only owner RLS; not production or full P1.03 acceptance");
