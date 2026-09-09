// Disposable PostgreSQL integration test, not a production or HTTP probe.
// Requires the parent-update fixture; refuses any other database or host.
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';

const exec = promisify(execFile);
assert.equal(process.env.PGHOST, '127.0.0.1', 'Only the local CI service is allowed');
assert.equal(process.env.PGDATABASE, 'sporv_parent_send_test', 'Disposable fixture database required');
const psqlArgs = ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1'];
const psql = async (sql, app = 'sporv_race_observer') => {
  const result = await exec('psql', [...psqlArgs, '-c', sql], {
    env: { ...process.env, PGAPPNAME: app }, timeout: 18000, maxBuffer: 200000,
  });
  return result.stdout.trim();
};
const scalar = async sql => JSON.parse(await psql(sql));
assert.equal(await psql('SELECT current_database()'), 'sporv_parent_send_test');
assert.equal(await psql("SELECT to_regprocedure('public.send_parent_update_entitled(uuid,uuid)') IS NOT NULL"), 't');

const org = 'c0000000-0000-0000-0000-000000000001';
const otherOrg = 'c0000000-0000-0000-0000-000000000002';
const owner = 'c1000000-0000-0000-0000-000000000001';
const otherOwner = 'c1000000-0000-0000-0000-000000000002';
const child = 'c2000000-0000-0000-0000-000000000001';
const otherChild = 'c2000000-0000-0000-0000-000000000002';
const parent = 'c3000000-0000-0000-0000-000000000001';
const otherParent = 'c3000000-0000-0000-0000-000000000002';
const updateId = n => `c4000000-0000-0000-0000-${String(n).padStart(12, '0')}`;

await psql(`
  -- Earlier failure fixtures intentionally lower the catalog limit to zero.
  UPDATE public.plan_entitlements SET send_quota_month=20 WHERE plan='free';
  UPDATE public.plan_entitlements SET send_quota_month=-1 WHERE plan IN ('solo','organization');
  INSERT INTO public.providers VALUES ('${org}','${owner}'),('${otherOrg}','${otherOwner}');
  INSERT INTO public.provider_entitlement_assignments VALUES ('${org}','solo'),('${otherOrg}','free');
  INSERT INTO public.athletes VALUES ('${child}','${parent}','Race fixture'),('${otherChild}','${otherParent}','Other fixture');
  INSERT INTO public.team_athletes(provider_id,athlete_id) VALUES ('${org}','${child}'),('${otherOrg}','${otherChild}');
  CREATE FUNCTION public.fixture_race_send(p_id uuid,p_actor uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
  DECLARE v_detail text;
  BEGIN RETURN public.send_parent_update_entitled(p_id,p_actor);
  EXCEPTION WHEN SQLSTATE 'PT402' THEN
    GET STACKED DIAGNOSTICS v_detail=PG_EXCEPTION_DETAIL;
    RETURN jsonb_build_object('kind','quota','detail',v_detail::jsonb);
  END $$;
`);

async function prepare(n, other = false) {
  await psql(`INSERT INTO public.parent_updates(id,provider_id,child_id,summary_body,status,approved_by,approved_at)
    VALUES ('${updateId(n)}','${other ? otherOrg : org}','${other ? otherChild : child}',
      'Concurrent approved fixture ${n}','approved','${other ? otherOwner : owner}',clock_timestamp())`);
}

async function hold(sql) {
  const proc = spawn('psql', psqlArgs, {
    env: { ...process.env, PGAPPNAME: 'sporv_race_controller' }, stdio: ['pipe', 'pipe', 'pipe'],
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

async function waitBlocked(names) {
  const deadline = Date.now() + 7000;
  while (Date.now() < deadline) {
    const count = Number(await psql(`SELECT count(*) FROM pg_stat_activity
      WHERE application_name IN (${names.map(n => `'${n}'`).join(',')})
      AND state='active' AND wait_event_type='Lock'`));
    if (count === names.length) return;
    await delay(30);
  }
  throw new Error(`Did not observe ${names.length} simultaneous blocked database sessions`);
}

const send = (n, name, other = false) => psql(`SET ROLE service_role;
  SELECT public.fixture_race_send('${updateId(n)}','${other ? otherOwner : owner}')`, name).then(JSON.parse);
const quotaLock = `SELECT pg_advisory_xact_lock(hashtextextended('${org}',41204))`;

// Two simultaneous sessions for the SAME owner-approved draft. This proves
// duplicate delivery serialization, not support for two distinct admin roles.
await prepare(1);
let release = await hold(quotaLock);
let first = send(1, 'sporv_race_same_a');
let second = send(1, 'sporv_race_same_b');
let both = Promise.all([first, second]);
both.catch(() => {});
try { await waitBlocked(['sporv_race_same_a', 'sporv_race_same_b']); }
finally { await release(); }
let results = await both;
assert.deepEqual(results.map(x => x.kind).sort(), ['already_sent', 'sent']);
assert.equal(results[0].receipt_id, results[1].receipt_id);
assert.equal(await scalar(`SELECT count(*) FROM public.notifications WHERE user_id='${parent}'`), 1);
assert.equal(await scalar(`SELECT count(*) FROM public.message_send_quota_claims WHERE provider_id='${org}' AND state='accepted'`), 1);
console.log('PASS same approved draft: two observed concurrent sessions, one notification, one quota acceptance, same receipt');

// One remaining Free slot, two different approved drafts: exactly one wins.
await psql(`UPDATE public.provider_entitlement_assignments SET plan_key='free' WHERE provider_id='${org}';
  INSERT INTO public.outbound_messages(provider_id,sent_at) SELECT '${org}',clock_timestamp() FROM generate_series(1,18)`);
await prepare(2); await prepare(3); await prepare(4, true);
release = await hold(quotaLock);
first = send(2, 'sporv_race_quota_a'); second = send(3, 'sporv_race_quota_b');
both = Promise.all([first, second]); both.catch(() => {});
try {
  await waitBlocked(['sporv_race_quota_a', 'sporv_race_quota_b']);
  // This must finish while the first organization's quota lock is still held.
  assert.equal((await send(4, 'sporv_race_other', true)).kind, 'sent');
} finally { await release(); }
results = await both;
assert.deepEqual(results.map(x => x.kind).sort(), ['quota', 'sent']);
assert.deepEqual(results.find(x => x.kind === 'quota').detail, {
  reason: 'send_quota_month', current_plan: 'free', upgrade_to: 'solo', limit: 20, current: 20,
});
assert.equal(await scalar(`SELECT count(*) FROM public.notifications WHERE user_id='${parent}'`), 2);
assert.equal(await scalar(`SELECT count(*) FROM public.parent_updates WHERE id IN ('${updateId(2)}','${updateId(3)}') AND status='approved'`), 1);
assert.equal(await scalar(`SELECT count(*) FROM public.notifications WHERE user_id='${otherParent}'`), 1);
console.log('PASS last Free slot: two observed concurrent sessions, one send, one exact402; other organization completes independently');

// A downgrade committed while a sender waits must be re-read before delivery.
await psql(`UPDATE public.provider_entitlement_assignments SET plan_key='solo' WHERE provider_id='${org}'`);
await prepare(5);
release = await hold(`UPDATE public.provider_entitlement_assignments SET plan_key='free' WHERE provider_id='${org}'`);
first = send(5, 'sporv_race_downgrade'); first.catch(() => {});
try { await waitBlocked(['sporv_race_downgrade']); }
finally { await release(); }
assert.equal((await first).kind, 'quota');
assert.equal(await psql(`SELECT status FROM public.parent_updates WHERE id='${updateId(5)}'`), 'approved');
assert.equal(await scalar(`SELECT count(*) FROM public.notifications WHERE user_id='${parent}'`), 2);
console.log('PASS downgrade while sender waits: current Free entitlement blocks delivery without altering the approved draft');
