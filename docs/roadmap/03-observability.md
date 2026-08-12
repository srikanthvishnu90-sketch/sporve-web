# 03 — Observability

**Status:** design only. Nothing here is implemented. No file under `src/` or
`api/` was touched to write this.
**Date:** 2026-08-11
**Scope:** `the-sporve-web` only. The Supabase/Flutter backend in
`~/SportsMan-main` has its own logs and is explicitly out of scope.

---

## 0. What is true right now (verified, with file:line)

| Claim | Evidence |
|---|---|
| No error tracking of any kind | `rg -in "sentry\|datadog\|logrocket\|bugsnag"` returns nothing outside `node_modules`. The only hits for `analytics` are `src/mod-companies.js` and `src/mod-insights.js`, which are product copy, not telemetry. |
| No global JS error handler | `rg -c "window.onerror\|unhandledrejection"` across `src/*.js` and `src/sporve-web.host.html` = 0. |
| CSP has no `'unsafe-inline'` and `connect-src 'self'` | `vercel.json` line 9 — `script-src 'self'` + 12 sha256 hashes; `connect-src 'self'`. |
| A third-party browser SDK would be blocked outright | Same line. Sentry/Datadog/LogRocket all POST to their own domain; `connect-src 'self'` refuses it. Loading their script would also fail `script-src`. **This is the constraint that decides the whole design.** |
| `build.py` hashes every inline `<script>` automatically | `src/build.py:299-308` (`re.findall(r"<script>(.*?)</script>")` → sha256 → base64), written back at `src/build.py:313`. |
| Inline event-handler attributes are forbidden and fail smoke | `src/build.py:290-291` states hashes cannot cover them; `src/smoke.sh:201-207` regexes ~40 `on*=` names in any case/quoting and prints `INLINEHANDLER`, which `src/smoke.sh:266` turns into a failure. |
| A stale hash blanks the entire site | `src/build.py:296`: "a stale hash blocks EVERY script and serves a blank" page. |
| `api/ai.js` already logs one line on failure | `api/ai.js:229` — `console.error("ai handler failed:", err?.message \|\| err)` then `502 ai_unavailable` at `api/ai.js:230`. That is the *only* server-side log in the repo. |
| `verify-prod.sh` is a gate, not monitoring | `.github/workflows/prod-verify.yml:9-12` — triggers are `push: [main]` and `workflow_dispatch`. No `schedule:`. It runs on merge and never again. |
| `/api/ai` already has same-origin, rate-limit, size and type gates worth copying | `api/ai.js:55-69` (sliding window), `:73-77` (client IP from `x-forwarded-for[0]`), `:83` (`x-forwarded-host` compare), `:154-157` (content-type), `:174-175` (8KB body cap). |
| The per-IP limiter is **not** a hard quota | `api/ai.js:44-52` states it plainly: the `Map` lives in one warm instance, Vercel runs several, cold starts reset it. |

**Could not confirm:** the Vercel billing plan. `.vercel/project.json` carries
only `projectId`/`orgId` (`team_mn5D4XBK4MgqL0KgNlzvzfky` — team-scoped, which
*suggests* Pro, but scope is not proof of plan). Vercel's published retention
for **runtime logs** is 1 hour on Hobby, 1 day on Pro, 3 days on Enterprise;
30 days only with the paid Observability Plus add-on. So `console.error` at
`api/ai.js:229` **is** retained and **is** visible in the dashboard — for
somewhere between one hour and one day, after which it is gone forever. Treat
the server log as a live tail, never as a record.

---

## 1. Client errors → `/api/clienterr`

### Why a same-origin endpoint is the only option

`connect-src 'self'` (vercel.json:9) means the browser will refuse any
`fetch`/`sendBeacon`/`XHR` to a host that is not `the-sporve-web.vercel.app`.
A same-origin `POST /api/clienterr` is permitted by that same directive with no
CSP change at all. Nothing in this section requires editing the policy.

### The reporter

A new inline `<script>` block near the **top** of `src/sporve-web.host.html`,
before the app modules, so it is installed before anything can throw.
`src/build.py:299` will hash it into `script-src` automatically. It must be a
`<script>` block — never an `on*=` attribute (`src/smoke.sh:201`).

```js
/* ---- error reporter ---- */
(function () {
  var SENT = 0, MAX = 5, LAST = 0, MIN_GAP = 1000, BUSY = false;
  var SEEN = Object.create(null);
  var BUILD = (document.querySelector('meta[name="sporve-build"]') || {}).content || "";

  // Strip anything that could be personal before it leaves the browser.
  function clean(s) {
    return String(s || "")
      .replace(/[\w.+-]+@[\w.-]+\.\w+/g, "[email]")
      .replace(/\b\d{7,}\b/g, "[num]")
      .replace(/\b(eyJ|sk-)[\w.\-]{10,}/g, "[token]")
      .replace(/Bearer\s+\S+/gi, "[token]")
      .slice(0, 180);
  }

  // Route id only. Never location.href — query strings and hashes carry ids.
  function route() {
    return (location.hash || "").replace(/[0-9a-f-]{8,}/gi, ":id").slice(0, 60);
  }

  function report(kind, name, msg, file, line, col) {
    if (BUSY || SENT >= MAX) return;                 // loop guard + budget
    var fp = name + "|" + file + "|" + line + "|" + col;
    if (SEEN[fp]) return;                            // dedupe a render loop
    var now = Date.now();
    if (now - LAST < MIN_GAP) return;                // floor between posts
    SEEN[fp] = 1; LAST = now; SENT++;
    BUSY = true;
    try {
      fetch("/api/clienterr", {
        method: "POST",
        keepalive: true,
        credentials: "omit",                         // never send cookies
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          v: 1, kind: kind, name: String(name).slice(0, 40),
          msg: clean(msg), file: String(file || "").slice(0, 120),
          line: line | 0, col: col | 0, route: route(), build: BUILD,
          w: window.innerWidth | 0
        })
      }).catch(function () {}).then(function () { BUSY = false; },
                                    function () { BUSY = false; });
    } catch (_) { BUSY = false; }
  }

  window.addEventListener("error", function (e) {
    report("error", (e.error && e.error.name) || "Error", e.message,
           e.filename, e.lineno, e.colno);
  });
  window.addEventListener("unhandledrejection", function (e) {
    var r = e.reason || {};
    report("rejection", r.name || "Rejection", r.message || String(r), "", 0, 0);
  });
  document.addEventListener("securitypolicyviolation", function (e) {
    report("csp", e.violatedDirective, e.blockedURI, e.sourceFile,
           e.lineNumber, 0);
  });
})();
```

### The feedback loop, named exactly

The loop that kills naive reporters: the reporter POSTs → the POST rejects
(offline, 429, 502) → an **unhandled promise rejection** fires → the
`unhandledrejection` listener fires → it POSTs again → forever, at network
speed. Four independent brakes, any one of which alone is insufficient:

1. **`.catch(function(){})` on the fetch is mandatory.** An un-caught rejected
   promise *is* the loop. This single line is the difference between a reporter
   and a self-DDoS.
2. **`BUSY` re-entrancy flag** — an error thrown *inside* the reporter cannot
   re-enter it.
3. **`SENT >= MAX` (5 per page load)** — a hard ceiling regardless of cause.
4. **Fingerprint dedupe + 1s floor** — a `render()` loop throwing 60×/sec
   posts once.

`fetch(..., {keepalive:true, credentials:"omit"})` is chosen over
`navigator.sendBeacon` deliberately: `sendBeacon` cannot suppress credentials,
so it would attach any future session cookie to a log write. `keepalive` caps
the body at 64KB; ours is under 1KB.

### What the reporter cannot see

If the CSP hashes go stale (`src/build.py:296`), **no script runs at all** —
including this one. The client reporter is structurally blind to the single
worst failure this build has. That is covered in §4 by CSP `report-uri`, which
the browser sends with no JS involved, and by the cron synthetic check.

---

## 2. Server errors — what `api/ai.js` should log, and where it goes

### Where it goes

`console.error` / `console.log` inside a Vercel function are captured as
**runtime logs**, visible under the project's Logs tab and via `vercel logs`.
Retention is 1h (Hobby) / 1d (Pro) / 3d (Enterprise); 30 days requires the paid
Observability Plus add-on. Plan not confirmed for this project (see §0). There
is no durable sink and no query-over-time without a paid Log Drain.

**Consequence for the design:** the log is for *diagnosis after you already
know something is wrong*. It can never be the thing that tells you. That job
belongs to §4.

### What to log

One line, one JSON object, so the dashboard's substring search is enough:

```js
console.error(JSON.stringify({
  lvl: "error", at: "api/ai", code: "upstream_failed",
  status: 502, ms: Date.now() - t0, model: MODEL,
  err: (err && err.name) || "Error",
  detail: String(err && err.message || "").slice(0, 200)
}));
```

Replaces the free-text line at `api/ai.js:229`. Also worth a `lvl:"warn"`
counter line (no body, no IP) on each rejection path already implemented:
`method_not_allowed` (`api/ai.js:151`), `unsupported_media_type` (`:156`),
`forbidden_origin` (`:159`), `rate_limited` (`:164`), `payload_too_large`
(`:175`), `text_too_long` (`:180`). Those six are the abuse signal.

`ai_not_configured` (`api/ai.js:169-170`) is different in kind — it means
`ANTHROPIC_API_KEY` is absent or was rotated, so the feature is 100% dead and
completely silent. Log it at `lvl:"alert"` and put it in §4.

### What must never appear in a server log

`text` — the coach's typed command (`api/ai.js:178-180`) — and `groups` — real
conversation names, posted from `src/sporve-web.host.html:8657`. Those are
message bodies and human names. See §5.

---

## 3. `/api/clienterr` — sampling, abuse, and why it is not a free write endpoint

New file `api/clienterr.js`, mirroring the gates already proven in `api/ai.js`:

| Gate | Copy from | Value here |
|---|---|---|
| POST only | `api/ai.js:149-152` | 405 otherwise |
| `content-type: application/json` | `api/ai.js:154-157` | 415 otherwise |
| Same-origin via `x-forwarded-host` | `api/ai.js:83` | 403 otherwise |
| Per-IP sliding window | `api/ai.js:55-69` | 10/min (vs 12/min for AI) |
| Body cap | `api/ai.js:174-175` | **2 KB**, not 8 KB |
| Response | — | `204 No Content`, always. Never echo input. |

**The property that matters most: this endpoint writes nothing durable.** Its
only side effect is one `console.error(JSON.stringify(shaped))` into a platform
log that rotates in ≤24h. There is no table, no blob, no queue, no file. An
attacker flooding it is not storing data on us — they are burning function
invocations, which the rate limiter and the 2KB cap bound, and which Vercel
bills as compute, not storage. A "free write endpoint" only exists if there is
a durable write; here there is not, by construction. **If a durable sink is
ever added, this whole paragraph stops being true and the endpoint needs an
auth token.** Write that in the file as a comment.

**Schema allowlist, both sides.** The server rebuilds the object from a closed
key list (`v, kind, name, msg, file, line, col, route, build, w`), coerces
ints, truncates strings, and drops everything else. So it cannot be used as
arbitrary key-value storage even at 2KB — the payload that gets logged is a
fixed shape regardless of what was posted.

**Honest caveat, same as `api/ai.js:44-52`:** the limiter is per warm instance.
Real ceiling is 10/min × live instances, and a cold start resets it. It raises
the cost of casual abuse; it is not a quota. A hard quota needs shared state
(Upstash Redis, free tier, already named at `api/ai.js:51`).

**Sampling.** Report 100% while traffic is pre-launch — the information value
of every error is high and the volume is near zero. Ship a single
`var SAMPLE = 1;` constant in the reporter so it can be dropped to `0.1` in one
line later. Rule when that day comes: **never sample the first occurrence of a
fingerprint**; sample repeats only. Losing the only instance of a novel bug to
a dice roll is the failure mode.

---

## 4. Alert vs record, and the free alert channel

**Record (look at it when investigating):** every client error, the six 4xx
counters, request latency, CSP violations that are not `script-src`.

**Alert (wake someone):**

| # | Condition | Why it is an alert | Detectable how |
|---|---|---|---|
| 1 | Homepage returns non-200, or body size deviates >10% from the committed `index.html` | Site is down or serving a stale/rolled-back build | cron + `curl` |
| 2 | The `sporve-build` stamp in production ≠ the stamp of `main`'s HEAD | Deploy silently failed or rolled back. `src/verify-prod.sh:23-31` already implements exactly this comparison | cron + `verify-prod.sh` |
| 3 | `POST /api/ai` returns 503 `ai_not_configured` | The API key is gone; the feature is dead and utterly silent (`api/ai.js:169`) | cron probe with a benign body |
| 4 | Any CSP `script-src` violation report | The hashes are stale → **the page is blank for every visitor** (`src/build.py:296`) | CSP `report-uri` (browser-native, needs no JS) |
| 5 | Security headers missing from the live response | A config change dropped the CSP | cron + `verify-prod.sh` |

**Cheapest mechanism, no paid service: a scheduled GitHub Actions workflow.**
The machinery already exists — `.github/workflows/prod-verify.yml` runs
`src/verify-prod.sh` — and it is missing exactly one thing:

```yaml
on:
  push:
    branches: [main]
  schedule:
    - cron: "*/15 * * * *"    # every 15 minutes
  workflow_dispatch:
```

A failing scheduled workflow emails the repo owner by default. That is the free
alert channel: no vendor, no key, no bill. Two honest limitations: GitHub cron
is best-effort and can be delayed 5–15 minutes, and **scheduled workflows are
auto-disabled after 60 days of repository inactivity** — so an unmaintained repo
loses its monitor silently, which is itself a thing to know.

Item 4 needs `report-uri /api/cspreport;` appended to the CSP value in
`vercel.json:9`. **Verified safe against the build:** `src/build.py:313` does
`re.sub(r"script-src [^;]*;", ...)` — it rewrites only the `script-src`
directive, so a sibling directive survives regeneration. `src/smoke.sh:185`
likewise regexes only `script-src ([^;]*);`. Ship `report-to` +
a `Reporting-Endpoints` header alongside it, since `report-uri` is deprecated
though still widely honoured. The CSP report endpoint must accept
`application/csp-report` and `application/reports+json`, unlike `api/ai.js:154`
which enforces `application/json`.

**Deliberately not solved:** alerting on client-error *volume*. Counting errors
across invocations needs shared state; the per-instance counter would undercount
to zero on a cold start, and shipping a number that is silently wrong is worse
than shipping none. If the owner wants it, the minimal step is Upstash Redis
free tier — one dependency that simultaneously fixes the `api/ai.js:44-52`
soft-quota caveat. That is the one upgrade worth its cost, and it is still $0.

---

## 5. PII — this is a COPPA product

**Never send to any log, client or server. Non-negotiable:**

- Message bodies — the coach's typed command (`text`, `api/ai.js:178`) and the
  AI's response. These routinely name a child.
- Conversation/group names (`groups`, posted from
  `src/sporve-web.host.html:8657`) — real people's names.
- Athlete name, age, date of birth, school, jersey number, photo URL.
- Parent name, email, phone, street address, precise geolocation.
- Any auth token, session id, cookie, JWT (`eyJ…`), or API key (`sk-…`),
  including `ANTHROPIC_API_KEY`.
- **Full URLs.** `location.href` can carry ids and emails in the query string
  or hash. Send the normalized route only, with id-shaped segments replaced.
- **The client IP.** It may be used *in memory* for rate limiting
  (`api/ai.js:73-77`) but must never be emitted. An IP tied to a minor's
  session is personal information under COPPA. Log nothing, not even a hash.
- **Stack traces — omitted in v1.** A frame's *function name* is safe; a string
  interpolated into an `Error` message inside that trace is not. The app is one
  file, so `file:line:col` is nearly as diagnostic and carries no strings.

**How the payload is shaped so it cannot carry them.** Three mechanisms, in
order of strength:

1. **Closed literal, not a spread.** The reporter constructs an object from an
   explicit key list. It never does `JSON.stringify(err)`, never spreads the
   event, never touches `event.target` or `e.detail`. Adding a PII field is
   therefore impossible by accident — it requires a new key in a literal, which
   shows up in a diff and in CodeRabbit's review (CLAUDE.md rule 11).
2. **Server re-validates against the same allowlist** and drops unknown keys.
   Defence in depth: a tampered client cannot post `{childName:…}` and have it
   land in the log, because the server never reads that key.
3. **Redaction on both sides.** `clean()` runs in the browser and again on the
   server — email-shaped strings, digit runs ≥7, `eyJ…`/`sk-…`, `Bearer …` —
   then a 180-char truncation. Belt and braces, because `msg` is the one field
   that is genuinely free text.

**Standing engineering rule that makes this hold:** never interpolate user data
into an `Error` message. Throw `new Error("booking_capacity_exceeded")`, not
`` new Error(`no slot for ${athlete.name}`) ``. Redaction is the net; not
putting it there in the first place is the actual control.

---

## 6. The smallest thing that ends "we find out from users"

Ship in this order. Each step is independently useful; stop whenever the
marginal value drops.

**Step 1 — one line of YAML.** Add `schedule: "*/15 * * * *"` to
`.github/workflows/prod-verify.yml:9`. `src/verify-prod.sh` already asserts the
build stamp, the headers and the gates. This alone converts a deploy gate into
a 15-minute uptime monitor with email alerting, at zero cost, with no new code.
It catches alerts 1, 2 and 5 — which is every total-outage case, the ones that
currently reach the owner via a user.

**Step 2 — the CSP report endpoint.** `report-uri /api/cspreport` in
`vercel.json:9` plus a ~30-line `api/cspreport.js`. Catches the blank-page-from-
stale-hash failure that no JS-based reporter can ever see.

**Step 3 — the client reporter + `/api/clienterr`.** ~60 lines of inline script
and ~50 lines of handler. Catches "a route throws for everyone" — but only once
someone reads the log. Its real value is diagnostic depth, not notification.

Steps 1 and 2 are the ones that end the sentence. Step 3 makes the answer to
"why?" take minutes instead of an afternoon.

**Smoke additions to land with step 3:** assert the reporter's fingerprint
string is present in `index.html`; assert the reporter lives inside a `<script>`
block so `src/build.py:299` hashes it; the existing `INLINEHANDLER` check at
`src/smoke.sh:201-207` already covers the attribute prohibition.

---

## 7. What this deliberately does not cover

- **Performance.** No Core Web Vitals, no LCP/INP, no bundle timing.
- **Session replay, breadcrumbs, user journeys.** Nothing that reconstructs
  what a specific person did. That is a deliberate COPPA posture, not a gap.
- **Distributed tracing.** No request ids threaded client → function → Supabase.
- **Durable history.** Vercel logs vanish in ≤24h. The only lasting record is
  the GitHub Actions run history for the synthetic check — pass/fail, not detail.
- **Error-rate alerting.** §4 explains why, and what it would cost to fix.
- **The Supabase/Flutter backend** (`~/SportsMan-main`). Different surface,
  different logs, different threat model. Not addressed here at all.
- **Users behind a CSP-stripping proxy or an injecting extension.** They will
  generate noise the reporter cannot distinguish from real defects.
- **Anything that requires a paid tier**: Log Drains, Observability Plus,
  uptime services. Every mechanism above is on the free path.

---

## Five-sentence technical reading

**What changed:** nothing executable — this is a design document; the only file
written is `docs/roadmap/03-observability.md`. **The mechanism:** the CSP at
`vercel.json:9` sets `connect-src 'self'`, which is a browser-enforced allowlist
of network destinations, so any third-party telemetry SDK is refused before it
sends a byte — the only viable client sink is a same-origin endpoint, and the
only outage detector that survives all scripts being blocked is the browser's
own CSP `report-uri` plus an out-of-band cron probe. **What it touches
downstream:** implementing it adds one inline `<script>` (auto-hashed by
`src/build.py:299-308`, so `vercel.json`'s `script-src` changes on the next
build), two new `api/*.js` handlers, one `report-uri` directive, and one
`schedule:` key in `.github/workflows/prod-verify.yml`. **What would break it:**
committing `index.html` without regenerating `vercel.json` — a stale sha256 hash
blocks every script and serves a blank page (`src/build.py:296`), which the
client reporter is structurally unable to report; and a `fetch` without
`.catch()` in the reporter turns an unhandled rejection into an infinite
self-POST loop. **How it was verified:** every claim in §0 was checked against
the named file:line with `rg`/`sed`; the safety of adding a sibling CSP
directive was confirmed by reading the regexes at `src/build.py:313` and
`src/smoke.sh:185`, which match `script-src` only; the Vercel plan could not be
confirmed and is stated as unconfirmed rather than assumed.
