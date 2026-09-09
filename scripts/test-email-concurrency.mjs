// Uses real independent PostgreSQL sessions, never a production credential.
import assert from 'node:assert/strict';
import {execFile,spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {setTimeout as delay} from 'node:timers/promises';
assert.equal(process.env.PGHOST,'127.0.0.1');
assert.equal(process.env.PGDATABASE,'sporv_parent_send_test');
const exec=promisify(execFile),args=['-X','-qAt','-v','ON_ERROR_STOP=1'];
async function sql(text,name='email_race_observer') {
  return (await exec('psql',[...args,'-c',text],{env:{...process.env,PGAPPNAME:name},timeout:18000,maxBuffer:200000})).stdout.trim();
}
assert.equal(await sql('SELECT current_database()'),'sporv_parent_send_test');
assert.equal(await sql("SELECT to_regprocedure('public.fixture_prepare_email(uuid)') IS NOT NULL"),'t');
const org='00000000-0000-0000-0000-000000000003';
const owner='10000000-0000-0000-0000-000000000003';
async function hold(statement) {
  const child=spawn('psql',args,{env:{...process.env,PGAPPNAME:'email_race_controller'},stdio:['pipe','pipe','pipe']});
  let out='',err=''; child.stdout.on('data',c=>{out+=c;}); child.stderr.on('data',c=>{err+=c;});
  const done=new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',code=>code===0?resolve():reject(new Error(err)));});
  done.catch(()=>{}); child.stdin.write(`BEGIN; ${statement}; SELECT 'READY';\n`);
  const deadline=Date.now()+8000;
  while(!out.includes('READY')) {
    if(child.exitCode!==null||Date.now()>deadline) {child.stdin.end('ROLLBACK;\n');await done;throw new Error('Controller lock unavailable');}
    await delay(20);
  }
  return async()=>{child.stdin.end('COMMIT;\n');await done;};
}
async function blocked(names) {
  const deadline=Date.now()+7000;
  while(Date.now()<deadline) {
    if(Number(await sql(`SELECT count(*) FROM pg_stat_activity WHERE application_name IN (${names.map(n=>`'${n}'`).join(',')})
      AND state='active' AND wait_event_type='Lock'`))===names.length) return;
    await delay(25);
  }
  throw new Error('Both real concurrent sessions were not observed waiting');
}
await sql(`UPDATE public.provider_entitlement_assignments SET plan_key='solo' WHERE provider_id='${org}';
  CREATE FUNCTION public.fixture_email_race_prepare(p_id uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
  DECLARE detail text; BEGIN RETURN public.fixture_prepare_email(p_id);
  EXCEPTION WHEN SQLSTATE 'PT402' THEN GET STACKED DIAGNOSTICS detail=PG_EXCEPTION_DETAIL;
    RETURN jsonb_build_object('kind','quota','detail',detail::jsonb); END $$;`);
const prepare=(id,name)=>sql(`SET ROLE service_role; SELECT public.fixture_email_race_prepare('${id}')`,name).then(JSON.parse);
const message=await sql('SELECT public.fixture_email()');
let release=await hold(`SELECT pg_advisory_xact_lock(hashtextextended('${org}',41204))`);
let pending=Promise.all([prepare(message,'email_same_a'),prepare(message,'email_same_b')]); pending.catch(()=>{});
try {await blocked(['email_same_a','email_same_b']);} finally {await release();}
let results=await pending;
assert.deepEqual(results.map(r=>r.kind).sort(),['held','ready']);
const ready=results.find(r=>r.kind==='ready');
assert.equal(results[0].dispatch_id,results[1].dispatch_id);
assert.equal(results[0].attempt_id,results[1].attempt_id);
assert.equal(Number(await sql(`SELECT count(*) FROM public.outbound_email_attempts WHERE dispatch_id='${ready.dispatch_id}'`)),1);
console.log('PASS simultaneous email dispatch: two observed sessions, one ready permission, one held, one attempt and quota claim');

release=await hold(`SELECT id FROM public.outbound_messages WHERE id='${message}' FOR UPDATE`);
const record=name=>sql(`SET ROLE service_role; SELECT public.record_lifecycle_email_result('${ready.dispatch_id}',
  '${ready.attempt_id}','${org}','${ready.wire_sha256}','accepted','concurrent-provider-fixture',null)`,name).then(JSON.parse);
pending=Promise.all([record('email_accept_a'),record('email_accept_b')]);pending.catch(()=>{});
try {await blocked(['email_accept_a','email_accept_b']);} finally {await release();}
results=await pending;
assert.deepEqual(results.map(r=>r.kind).sort(),['already_recorded','recorded']);
assert.equal(results[0].result_id,results[1].result_id);
assert.equal(Number(await sql(`SELECT count(*) FROM public.outbound_email_results WHERE dispatch_id='${ready.dispatch_id}'`)),1);
console.log('PASS simultaneous email acceptance: one immutable provider receipt and one quota acceptance, replay identical');

// Compete across channels, not merely two email requests with independent caps.
await sql(`UPDATE public.provider_entitlement_assignments SET plan_key='free' WHERE provider_id='${org}';
  UPDATE public.plan_entitlements SET send_quota_month=3 WHERE plan='free';
  INSERT INTO public.athletes VALUES ('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','Email race');
  INSERT INTO public.team_athletes(provider_id,athlete_id) VALUES ('${org}','e2000000-0000-0000-0000-000000000001');
  INSERT INTO public.parent_updates(id,provider_id,child_id,summary_body,status,approved_by,approved_at)
    VALUES ('e4000000-0000-0000-0000-000000000001','${org}','e2000000-0000-0000-0000-000000000001',
      'Approved mixed-channel fixture','approved','${owner}',clock_timestamp());`);
assert.equal(Number(await sql(`SELECT count(*) FROM public.message_send_quota_claims WHERE provider_id='${org}'`)),2);
const second=await sql('SELECT public.fixture_email()');
release=await hold(`SELECT pg_advisory_xact_lock(hashtextextended('${org}',41204))`);
pending=Promise.all([prepare(second,'email_slot'),sql(`SET ROLE service_role; SELECT public.fixture_race_send(
  'e4000000-0000-0000-0000-000000000001','${owner}')`,'inbox_slot').then(JSON.parse)]);pending.catch(()=>{});
try {await blocked(['email_slot','inbox_slot']);} finally {await release();}
results=await pending;
assert.equal(results.filter(r=>r.kind==='quota').length,1);
assert.equal(results.filter(r=>['ready','sent'].includes(r.kind)).length,1);
assert.deepEqual(results.find(r=>r.kind==='quota').detail,{reason:'send_quota_month',current_plan:'free',upgrade_to:'solo',limit:3,current:3});
assert.equal(Number(await sql(`SELECT count(*) FROM public.message_send_quota_claims WHERE provider_id='${org}'`)),3);
console.log('PASS mixed inbox/email last slot: two observed sessions share one allowance; loser exact402, total claims three');
