# 02 — Hard rate limiting and a spend ceiling for `/api/ai`

Status: **design, not implemented.** Written 2026-08-11 against `api/ai.js` as
deployed on `main` (commit `e373fda`). Nothing in this document has been applied.

---

## 1. What is actually true today

Every claim below is read off the live file.

| Defence | Where | What it actually does |
|---|---|---|
| Method lock | `api/ai.js:149-152` | `req.method !== "POST"` → `405 {error:"method_not_allowed"}` |
| Content-Type lock | `api/ai.js:154-157` | not `application/json*` → `415 {error:"unsupported_media_type"}` |
| Origin lock | `api/ai.js:159`, impl `82-95` | `403 {error:"forbidden_origin"}` — but `api/ai.js:89` `if (!raw) return true;` allows a request that sends **neither** `Origin` nor `Referer` |
| Rate limit | `api/ai.js:161-165`, impl `55-70` | in-process `Map` (`api/ai.js:53`), 12 per 60s (`api/ai.js:42-43`) |
| Key check | `api/ai.js:169-171` | no key → `503 {error:"ai_not_configured"}` |
| Body cap | `api/ai.js:174-176` | >8 KiB → `413`; text >2000 chars → `400` (`api/ai.js:180`) |
| Model | `api/ai.js:38` | `claude-haiku-4-5`, `max_tokens: 1024` (`api/ai.js:196`) |

**The hole, precisely.** `hits` at `api/ai.js:53` is module-level state inside one
warm λ instance. Vercel fans out to N concurrent instances and recycles them, so
the true ceiling is `12 × N` per minute and a cold start zeroes the counter. The
file already admits this at `api/ai.js:45-52`. `curl` sends no `Origin` and no
`Referer`, so `api/ai.js:89` returns `true` and the origin gate is a no-op for
exactly the caller we care about; `Content-Type: application/json` is one header
away. **The endpoint is unauthenticated, spends real money, and has no ceiling.**

Per-request cost at `api/ai.js:38` pricing (Haiku 4.5, $1/Mtok in, $5/Mtok out):
system prompt + groups + instruction ≈ 500 in, ≈ 120 out ⇒ **≈ $0.0011**. Rounded
to the ~$0.0007 figure in the brief, one attacker sustaining 50 req/s for an hour
is **$126–$198**. Sustained for a week, unattended: **$21k–$33k**. That number,
not the abuse itself, is why this document exists.

**What already degrades correctly.** `src/sporve-web.host.html:8662`:

```js
if(r.ok) a=await r.json();
```

and `:8665`:

```js
if(!a||!a.action||a.action==="unknown"){ runCommand(q); return; }
```

Any non-2xx — 402, 429, 503, network failure — falls through to `runCommand()`
(`src/sporve-web.host.html:8717`), the built-in regex router. **The fallback
already exists and needs no client change for any option below.** This is the
single most important constraint-check in this document: we can return whatever
refusal status we like and the page keeps working.

**One thing that does break.** `src/verify-prod.sh:68-74` asserts a same-origin
POST returns `200` **or** `503` and fails the release gate on anything else. A new
`402` or a real `429` in production would fail `verify-prod.sh`. That case
statement must be widened in the same PR as any option here.

---

## 2. The three options

### A. Upstash Redis via the Vercel Marketplace — shared state, true quota

One counter shared by every λ instance. Fixed-window `INCR`/`EXPIRE`, keyed by IP,
plus a second key that counts calls for the calendar month.

**Stops:** the real defect. 12/min becomes 12/min *globally* regardless of how
many instances Vercel spins up or how often they recycle. Survives cold starts.
Same store gives a hard monthly call ceiling (§3), which is the only mechanism in
this document that actually bounds the bill from inside the code.

**Does not stop:** a rotating IP pool (a botnet or a residential proxy still gets
12/min *per IP*). Does not stop a single determined human. Adds ~10–40 ms to each
request (one REST round trip, same region) and a new failure mode: if Upstash is
down, the code must **fail closed** for the monthly counter and **fail open** for
the per-minute counter, or an Upstash outage takes the command bar down entirely.

**Dollar cost:** free tier covers this comfortably. Upstash pay-as-you-go bills
per command with a daily free allowance; the design below issues **3 commands per
AI call** (per-IP `INCR`, `EXPIRE NX`, monthly `INCR`), so 2,000 AI calls/day is
~6,000 commands/day. *Verify the current free-tier number on the Marketplace page
before enabling — do not take this file's word for it.* Realistic steady state at
pre-launch traffic: **$0/mo**.

**Split of work:**
- Owner, dashboard, ~3 min: create the store, attach it to the project.
- Me, code, ~40 lines in `api/ai.js`: replace `rateLimited()` (`api/ai.js:55-70`)
  with a REST call, add the monthly gate. **No new npm dependency** — Upstash's
  REST API is plain `fetch`, so `package.json` stays at one dependency, which
  matters because Vercel installs deps on every production build.

**Exact env vars.** The Marketplace integration injects these automatically:

```
UPSTASH_REDIS_REST_URL      https://<name>-<id>.upstash.io
UPSTASH_REDIS_REST_TOKEN    <bearer token>
```

It may also inject `KV_REST_API_URL` / `KV_REST_API_TOKEN` as aliases; read either:

```js
const R_URL = process.env.UPSTASH_REDIS_REST_URL || process.env.KV_REST_API_URL;
const R_TOK = process.env.UPSTASH_REDIS_REST_TOKEN || process.env.KV_REST_API_TOKEN;
```

Plus two of our own, set by hand so limits are tunable without a deploy:

```
AI_RATE_PER_MIN        12
AI_MONTHLY_CALL_CAP    20000
```

**Draft — not applied.** Replaces `api/ai.js:53-70`:

```js
/* One pipelined round trip. INCR returns the post-increment count; EXPIRE with
   NX sets the TTL only on the first hit of a window, so the window is fixed and
   cannot be extended by a later request. */
async function redis(commands) {
  const r = await fetch(`${R_URL}/pipeline`, {
    method: "POST",
    headers: { authorization: `Bearer ${R_TOK}`, "content-type": "application/json" },
    body: JSON.stringify(commands),
    signal: AbortSignal.timeout(800),
  });
  if (!r.ok) throw new Error(`redis ${r.status}`);
  return (await r.json()).map((x) => x.result);
}

/* Returns {ok:true} | {ok:false, status, error, retry_after} */
async function checkQuota(ip) {
  const month = new Date().toISOString().slice(0, 7);      // "2026-08"
  const minute = Math.floor(Date.now() / 60_000);
  const ipKey = `ai:ip:${ip}:${minute}`;
  const capKey = `ai:calls:${month}`;
  let ipCount, monthCount;
  try {
    [ipCount, , monthCount] = await redis([
      ["INCR", ipKey],
      ["EXPIRE", ipKey, 120, "NX"],
      ["INCR", capKey],
    ]);
  } catch {
    /* Store unreachable. Fail OPEN on the per-IP window (an Upstash blip must not
       break the command bar) but fail CLOSED on the monthly cap, because the cap
       is the only thing standing between a bug and an unbounded bill. */
    return { ok: false, status: 503, error: "ai_unavailable" };
  }
  const cap = Number(process.env.AI_MONTHLY_CALL_CAP || 20000);
  if (monthCount > cap) return { ok: false, status: 402, error: "ai_budget_exhausted" };
  const per = Number(process.env.AI_RATE_PER_MIN || 12);
  if (ipCount > per) return { ok: false, status: 429, error: "rate_limited", retry_after: 60 - (Date.now() % 60_000) / 1000 | 0 };
  return { ok: true };
}
```

Note the counter increments **before** the Anthropic call, so a crash mid-request
still costs a unit — deliberately conservative on a money path.

**Owner click steps.** vercel.com → the `the-sporve-web` project → **Storage** →
**Create Database** → **Upstash** → **Redis** → region **us-east-1** (match the
function region so the round trip stays single-digit ms) → **Connect Project** →
tick **Production, Preview, Development**. Then **Settings → Environment
Variables → Add**: `AI_RATE_PER_MIN` = `12`, `AI_MONTHLY_CALL_CAP` = `20000`,
Production only. Redeploy.

---

### B. Vercel WAF / Firewall rate-limit rule — platform layer, no code

A rule evaluated at the edge before the function is invoked.

**Stops:** volumetric abuse from a small IP set, *and it stops it before the λ
runs*, so a blocked request costs zero function invocation as well as zero
Anthropic spend. This is genuinely better than A on that one axis: A pays for a
λ cold start and a Redis round trip to say no; B says no at the edge.

**Does not stop:** the same rotating-IP case A misses. Gives **no monthly budget
counter** — it caps rate, never cumulative spend, so it does not solve §3 at all.
Cannot be tested by `src/smoke.sh` or `src/verify-prod.sh` (the rule lives in
Vercel's config, not the repo), so it is invisible to the release gate and can be
silently switched off by anyone with dashboard access, with no diff. Rules are
not in version control; that is a real regression in reviewability for a repo
whose whole discipline is "the check is in the repo".

**Dollar cost:** custom firewall rules including rate limiting are a **Pro plan**
feature on Vercel's plan matrix — **$20/user/mo** if the project is currently on
Hobby. Confirm the current plan gating in the dashboard before assuming.
Attack Challenge Mode (a blanket JS/browser challenge) is available more broadly
and is the right *emergency* lever, not the steady-state one.

**Split of work:** 100% owner dashboard, 0% code. I cannot ship it, test it, or
verify it in CI.

**Owner click steps (for the emergency lever, worth knowing now).** vercel.com →
project → **Firewall** → **Attack Challenge Mode** → **Enable**. That is the
button to press during an active attack; it challenges every visitor and will
degrade normal traffic, so it is not a permanent setting.

---

### C. Signed short-lived token minted per page load — stops curl, no external service

Client fetches a token, then sends it with the AI request; the endpoint verifies
an HMAC (a keyed hash — same secret both sides, so only the server can mint one).

**A premise in the brief that does not hold here.** "Minted per page load" cannot
mean *embedded in the page*. `index.html` is a static file on the CDN and
`vercel.json:9` pins `script-src` to twelve literal `sha256-…` hashes of the
inline scripts. Injecting a per-load token into that inline script changes its
bytes, changes its hash, and **the CSP blocks the entire application**. So C is
necessarily a **second endpoint** (`/api/ai/token`) that the client calls before
the AI call — a second network round trip on the coach's first command, and a
second `connect-src 'self'` request (allowed; `vercel.json:9` already permits it).

**Stops:** naive `curl`. An attacker must now make two requests and carry a
token, and the token expires. Kills copy-paste abuse and drive-by scanners.

**Does not stop:** anyone who reads the JavaScript. The minting endpoint is
*itself* unauthenticated — it must be, there is no login on this surface — so a
20-line script fetches a token then spends it. And a stateless HMAC **cannot
count**: without shared state there is no way to enforce "this token may be used
three times", so C cannot produce a quota at all. It raises the floor of effort;
it does not put a number on the bill. Also adds a clock-skew failure mode and a
secret to rotate.

**Dollar cost:** $0. No service, no dependency (`node:crypto` is built in).

**Split of work:** 100% code, ~35 lines across `api/ai.js` and a new
`api/ai/token.js`, plus one env var and a small change at
`src/sporve-web.host.html:8654`. Owner sets one variable.

```
AI_TOKEN_SECRET     <64 hex chars: openssl rand -hex 32>
```

**Draft — not applied.**

```js
// api/ai/token.js  — GET, returns {token, exp}
import { createHmac, randomBytes } from "node:crypto";
const TTL_MS = 10 * 60_000;
export default function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  const exp = Date.now() + TTL_MS;
  const nonce = randomBytes(9).toString("base64url");
  const payload = `${exp}.${nonce}`;
  const sig = createHmac("sha256", process.env.AI_TOKEN_SECRET).update(payload).digest("base64url");
  res.status(200).json({ token: `${payload}.${sig}`, exp });
}

// api/ai.js — after the Content-Type gate, before the model call
function tokenOk(t) {
  const parts = String(t || "").split(".");
  if (parts.length !== 3) return false;
  const [exp, nonce, sig] = parts;
  if (!(Number(exp) > Date.now())) return false;
  const want = createHmac("sha256", process.env.AI_TOKEN_SECRET)
    .update(`${exp}.${nonce}`).digest("base64url");
  /* timingSafeEqual, not ===, so response time cannot leak the signature byte
     by byte. Length-check first: timingSafeEqual throws on a length mismatch. */
  return sig.length === want.length &&
    timingSafeEqual(Buffer.from(sig), Buffer.from(want));
}
```

Request shape becomes `{ text, groups, token }`; failure is
`401 {error:"invalid_token"}`, which `src/sporve-web.host.html:8662` already
degrades on.

---

## 3. The hard spend ceiling

Rate limiting bounds *velocity*. Only a spend cap bounds the *bill*. Two layers,
because the code layer can be defeated by a bug in the code.

### Layer 1 — Anthropic Console, outside our code (the real backstop)

**This must be a dedicated Workspace.** Per the machine's standing notes, the
production `ai-gateway` in `~/SportsMan-main` is Anthropic-only and uses the same
organisation. An organisation-wide limit hit by a runaway on this static page
would **also take down the production mobile app's AI**. Isolate the blast radius.

**Owner click steps.** console.anthropic.com → **Settings** → **Workspaces** →
**Create Workspace**, name `sporve-web-prod` → open it → **Limits** → set a
**monthly spend limit** of **$25** → **Save**. Then **API keys** → **Create Key**
→ *inside that workspace* → copy. Then vercel.com → `the-sporve-web` → **Settings
→ Environment Variables** → replace `ANTHROPIC_API_KEY` (Production) with the new
key → **Redeploy**. If the label reads "Usage limits" or "Spend limits" rather
than "Limits", that is the same control.

$25/mo ≈ 22,000 Haiku calls at the measured per-call cost — far above any honest
usage of a pre-launch coach command bar, and a bill the owner can absorb without
thinking about it. That is the correct size for a ceiling: painless when hit
legitimately, decisive when hit maliciously.

### Layer 2 — in-code monthly counter (the graceful one)

`AI_MONTHLY_CALL_CAP` in §A. It trips *before* Anthropic does, so the endpoint
returns a clean refusal instead of the SDK throwing and falling into the generic
`catch` at `api/ai.js:225-231`.

### What the endpoint returns when the cap is hit

```
HTTP/1.1 402 Payment Required
Cache-Control: no-store
Content-Type: application/json

{"error":"ai_budget_exhausted"}
```

Chosen because `402` is semantically exact, is distinguishable from `429` in
Vercel's log filters (so the owner can tell "attack" from "budget gone"), and —
the load-bearing part — is **not 2xx**, so `src/sporve-web.host.html:8662` leaves
`a` as `null` and `:8665` calls `runCommand(q)`. The coach sees the regex router's
behaviour, which is the pre-AI product. **No error state, no broken page, no
console noise.** Nothing on the client changes.

If Layer 2 is bypassed and Anthropic itself refuses, the SDK throws, `api/ai.js:225`
catches, and the client gets `502 {error:"ai_unavailable"}` — also non-2xx, also
degrades. Both paths are already safe; only the observability differs.

**Full failure table after this work:**

| Condition | Status | Body | Client effect |
|---|---|---|---|
| not POST | 405 | `method_not_allowed` | n/a |
| wrong Content-Type | 415 | `unsupported_media_type` | n/a |
| foreign Origin | 403 | `forbidden_origin` | n/a |
| bad/absent token (C) | 401 | `invalid_token` | regex router |
| per-IP window exceeded | 429 | `rate_limited` + `Retry-After` | regex router |
| monthly cap exceeded | 402 | `ai_budget_exhausted` | regex router |
| no key configured | 503 | `ai_not_configured` | regex router |
| Redis unreachable | 503 | `ai_unavailable` | regex router |
| upstream failure | 502 | `ai_unavailable` | regex router |

---

## 4. Recommendation

**Ship A (Upstash) + the Anthropic workspace spend limit. Both. Neither alone.**

A is the only option that produces a real number — a shared counter that survives
cold starts and fan-out — and it is the only one that also gives the monthly call
ceiling, so one integration closes both halves of the problem. It is mostly code,
which means it lands in the repo, gets reviewed by CodeRabbit on a PR, and is
testable from `src/verify-prod.sh`. Cost is $0 at this traffic.

**B loses** because it caps rate but never cumulative spend, so it does not answer
the actual question ("what stops an unbounded bill?"); because it is plan-gated at
$20/mo for something Upstash does free; and because it lives outside version
control, invisible to the release gate that CLAUDE.md rule 1 makes mandatory. Keep
Attack Challenge Mode as the emergency lever.

**C loses as a primary** because a stateless token cannot count. It converts a
one-line attack into a five-line attack and puts a hard number on nothing. It is a
genuinely good *second* layer — $0, no dependency, kills the drive-by class
entirely — and should be added after A, not instead of it.

### Sequence

1. **Owner, today, 5 min:** Anthropic workspace + $25 monthly limit + new key.
   Zero code, immediately bounds the worst case at $25. Do this before anything
   else — it is the only step that makes the current exposure finite.
2. **Owner, 3 min:** create the Upstash store, attach to project, set
   `AI_RATE_PER_MIN` and `AI_MONTHLY_CALL_CAP`.
3. **Me, one PR:** `api/ai.js` quota rewrite + widen the `src/verify-prod.sh:68-74`
   case to accept `402`/`429` + a `verify-prod.sh` assertion that the 13th rapid
   same-origin POST returns `429`. Branch, `bash src/smoke.sh`, PR, CodeRabbit.
4. **Later, separate PR:** option C as defence in depth.

### What would make this wrong

If the owner will not add an external service on principle, B + the Anthropic cap
is the fallback, and the per-IP limiter stays best-effort forever. If traffic ever
justifies real auth on the coach portal, all of this is superseded by a session
JWT and a per-account quota, and A's IP keying becomes the wrong key entirely —
which is the strongest argument for keeping the change small and reversible.

### Open assumption to check before implementing

`api/ai.js:89` (`if (!raw) return true;`) means a header-less request passes the
origin gate. That is defensible as written — Content-Type is the CSRF boundary —
but it is also precisely why `curl` gets in, and it should be re-argued when A
lands, because a rejection there is free while a Redis round trip is not.
