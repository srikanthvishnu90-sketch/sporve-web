# 01 — The first unit-test harness

Status: spec, not implemented. Written 2026-08-11 against commit `e373fda`.
Author: Clo (MODE: thesis). Implementable in one pass by one agent.

This document is the whole design. Do not write tests before reading
§2 — the access mechanism is the entire difficulty, and picking a different
one silently invalidates every case below.

---

## 0. Why

19,767 lines of product JavaScript. One test file: `src/smoke.sh`, 28 `pass`/
`fail` assertions (`src/smoke.sh:26-27` define the primitives), all of them
end-to-end through a real browser. Nothing tests a function in isolation.

The cost is documented in the source itself. `src/sporve-web.host.html:3141-3153`:

> the rate was left at 9% in two files after PR #35 and again after #47 — the
> same constant was fixed three times because it was authored in five places.

`src/smoke.sh:338-341` says the same thing. The existing fee tripwires are a
`grep` for re-declared constants (`smoke.sh:343`) and a DOM scrape for rendered
percentage strings (`smoke.sh:348-364`). Both check the *rate*. **Neither
checks the arithmetic.** No assertion in this repo says that 12% of $80 is
$9.60. That is the hole this document closes.

---

## 1. Hard constraints (each verified against the repo)

| Constraint | Verified |
|---|---|
| No npm dependency may be added | `package.json` has exactly one dependency, `@anthropic-ai/sdk`, and its own `comment` field explains that playwright is deliberately excluded so Vercel does not install it per production build. The same reasoning bans a test framework. |
| Node's built-in runner is available | `node --version` → `v24.16.0` locally; `.github/workflows/pr-checks.yml:27-28` pins `node-version: "22"`. `node --test` and `node:assert/strict` exist in both. |
| Nothing is exported | Host functions are top-level in a classic `<script>` (`src/sporve-web.host.html:2925` and `:8807` are the only two `<script>` opens). Modules are IIFEs: `src/mod-payments.js:24` opens `(function () {`, `:1506` closes `})();`, and the only export is `window.MOD_PAYMENTS` (`:1487`) which exposes `css / views / modals / wire / state` — **not** `feeOn` or `bandFor`. |
| Must run in `src/smoke.sh` and in CI | Both wire-ups specified in §7. |
| `src/build.py` inlines `mod-*.js` only | `src/build.py:26` globs `mod-*.js`; `src/build.py:8-13` is the explicit `ORDER` list; the single injection point is the `<!--MODULES-->` marker at `src/sporve-web.host.html:8805`. A new `lib-*.js` would **not** be picked up without editing `build.py`. |

---

## 2. How a test file reaches the code — the decision

### Chosen: **scope-return evaluation in `node:vm`**

A loader reads the *source text*, wraps it so the values we want are
**returned** rather than left in an unreachable scope, and evaluates it inside a
`node:vm` context carrying a ~40-line browser stub. Zero changes to any file
under `src/`.

Three mechanical facts make it work, and the loader asserts all three so a
future refactor breaks the harness loudly instead of silently passing:

**(a) The host is two classic script blocks.** `<script>` at
`sporve-web.host.html:2925` closes at `:8802`; a second opens at `:8807` and
closes at `:8903`. Classic scripts share one global scope, so block 2's
`loadState` (`:8848`) legitimately reads block 1's `S` (`:3225`). The loader
extracts both with `/<script>([\s\S]*?)<\/script>/g` and concatenates them in
order.

**(b) The boot tail is a unique, cuttable string.** `bootModules()` appears
three times: the declaration at `:6154`, a comment at `:8890`, and the top-level
call at `:8893`. Only the call is preceded by a newline and followed by `();`,
so `"\nbootModules();"` is a unique cut point. Everything the tests need
(`PERSIST_KEY` `:8834`, `saveState` `:8841`, `loadState` `:8848`,
`scheduleSave` `:8887`) is declared *before* it; everything that needs a real
DOM (`render()` `:8895`) comes after. The loader truncates there and throws if
the string is not found exactly once.

**(c) Only six top-level statements touch the browser.** Verified by
`rg -n "^(document|window|sessionStorage)\." src/sporve-web.host.html`:
`:7843` `:8757` `:8777` `:8792` `:8797` `:8902` (the last is after the cut).
All are `addEventListener` or a `querySelectorAll(...).forEach`, so a stub that
returns `[]` and swallows listeners makes them no-ops.

The wrapper the loader builds:

```
(function(){
<block1>
<block2 truncated at "\nbootModules();">
;return { S, FEE_PCT, FEE_RATE, money, PROGRAMS, TODAY,
          cmdNorm, resolveGroup, loadState, saveState,
          EPHEMERAL, PERSIST_KEY };
})()
```

Do **not** prepend `"use strict"` — the host is sloppy-mode and
`sporve-web.host.html:8901` reassigns the `render` function declaration.

**Modules use the same trick with a different seam.** `mod-payments.js` is
`"use strict";` + comment + one top-level IIFE. The loader rewrites two anchors:
the first `(function () {` becomes `var __out = (function () {`, and the
trailing `})();` becomes `; return { feeOn, pctOf, bandFor, POLICIES, usd,
sessionStart, hoursUntil }; })();`. `var` at the top level of a vm script does
become a context property even under `"use strict"`, so the loader reads
`sandbox.__out`.

**The module must see the real host constant.** Before evaluating the module,
`Object.assign(sandbox, hostExports)` so `FEE_PCT` resolves through the scope
chain to the host's `const FEE_PCT = 12` (`sporve-web.host.html:3154`).
**Never stub `FEE_PCT` in the harness.** A stubbed rate lets host and module
drift while the suite stays green — which is precisely the bug class that
produced three fee fixes. There must be exactly one literal `12` in the entire
suite, in one assertion (§3, case F0).

### Cost of this choice — state it plainly

1. The harness is coupled to three structural facts of the source. If a
   refactor splits the host into three `<script>` blocks, renames the boot call,
   or converts a module away from a bare IIFE, the loader throws. That is the
   intended failure mode, but it is a real maintenance tax.
2. `vm` is not a browser. Anything reading layout, computed style, or a real
   DOM node cannot be tested here — that remains `smoke.sh`'s job, and this
   suite does not replace a single existing assertion.
3. Evaluating the ~5,900-line host per test costs roughly 100ms. A fresh scope
   per test is required (`loadState` mutates `S` in place, `:8874`), so budget
   ~3s for 30 tests. Cache the file *read*, never the *evaluation*.
4. Coverage is limited to functions that survive the cut, i.e. anything
   declared before `bootModules()`. That is nearly everything in the host.

### Rejected, with reasons

- **Extract pure helpers to `src/lib-*.js`.** Costs a `build.py` change
  (`build.py:26` globs `mod-*.js`; `build.py:8` is a hand-ordered list) plus a
  second inline marker. Worse, it *cannot cover two of the four required
  targets*: `loadState` (`:8848`) closes over `S` and `sessionStorage`, and
  `resolveGroup` (`:8627`) closes over `S.conversations`. Moving them changes
  behaviour, which CLAUDE.md rule 2 forbids. And `package.json` declares
  `"type": "module"`, so a classic-script lib is not `import`-able as ESM
  without a `.cjs` rename that `build.py` would then have to special-case.
- **Evaluate the built `index.html`.** 1,836,918 bytes, the overwhelming
  majority base64 fonts and hero images. Parsing that per test is waste, and
  because modules are already inlined as IIFEs you still cannot reach `feeOn`.
- **jsdom / vitest / jest.** npm dependency. Banned by constraint.

### Files to create

```
test/_scope.mjs           loader: loadHost(), loadModule(name, exportNames), stubs
test/fee.test.mjs
test/refund.test.mjs
test/resolve-group.test.mjs
test/load-state.test.mjs
```

`_scope.mjs` exports `loadHost()` → fresh `{exports, sandbox}` per call, and
`loadPayments()` → `{host, mod}` with the host globals already assigned.
Browser stub surface, minimum viable: `document.querySelectorAll → []`,
`document.getElementById → {innerHTML:"", classList:{add(){},remove(){}},
style:{}, dataset:{}}`, `document.addEventListener`, `window.addEventListener`,
`window.scrollTo`, `window.matchMedia → {matches:false, addEventListener(){}}`,
`sessionStorage` / `localStorage` as Map-backed `getItem/setItem/removeItem`
returning `null` on miss, `setTimeout/clearTimeout`, `console`, `navigator:{}`,
`location:{href:"file:///index.html"}`, `fetch` that rejects.

**Unverified, and the implementer will discover it in the first run:** I checked
only top-level statements *beginning* with `document`/`window`/`sessionStorage`.
A bare top-level call like `initFoo();` that reaches the DOM indirectly would
also need a stub. If evaluation throws, read the stack, add the stub, move on —
it is a bounded, one-time cost.

---

## 3. Priority 1 — fee math (blast radius: every dollar the company moves)

### F0 — the single source

**Function:** `FEE_PCT`, `src/sporve-web.host.html:3154`; `FEE_RATE`, `:3155`.

| Input | Expected |
|---|---|
| `host.FEE_PCT` | `12` |
| `host.FEE_RATE` | `0.12` |
| `mod.feeOn` resolving its own `FEE_PCT` | must equal `host.FEE_PCT` |

**Caught:** the PR #35 / #47 regression where the constant was corrected in the
host and left at 9 elsewhere. This is the only place `12` is written in the
suite; every other case derives from `host.FEE_PCT`.

### F1 — `feeOn`

**Function:** `const feeOn = cents => Math.round(cents * FEE_PCT / 100);`
— `src/mod-payments.js:141`. Integer cents in, integer cents out.

| Input (cents) | Expected | What it catches |
|---|---|---|
| `8000` | `960` | **$80 → $9.60.** The case that has never existed. A rate of 9 gives `720`, a rate of 18 gives `1440` — both fail loudly. |
| `0` | `0` | Free listing does not generate a fee row. |
| `1` | `0` | Sub-cent fees floor to zero under `Math.round`. Pins current behaviour; a swap to `Math.ceil` would bill a coach 1¢ on a 1¢ booking and fail here. |
| `3000` | `360`, and `3000 - 360 === 2640` | The **incidence** invariant in its simplest form: coach nets 88%. |
| property, `c` in `0..100000` | `feeOn(c) + (c - feeOn(c)) === c` | No cent is created or destroyed by rounding. |

**Verified arithmetic note worth encoding as a comment, not a test:** at 12% no
integer cent amount can produce a `.5` rounding tie. `c·12/100 = k + 0.5`
requires `c·6 = 50k + 25`, even on the left and odd on the right. The tie-break
direction of `Math.round` is therefore unreachable at this rate and needs no
test — but it *becomes* reachable at any odd rate, so if `FEE_PCT` ever changes,
F1 must be revisited.

### F2 — incidence: the parent pays the list price

**Under test:** the charge record built at checkout, `src/mod-payments.js`
around `:344` and `:388-391` (`"You pay the coach's price. The 12% fee is
Sporve's share of it"`), and the payout rows at
`src/sporve-web.host.html:5615-5616`.

| Case | Expected |
|---|---|
| program at `8000` cents, checkout charge | `charge.gross === 8000` (the parent is charged the list price, **not** `8000 + fee`) |
| same | `charge.fee === feeOn(charge.gross)` |
| same | `charge.net === charge.gross - charge.fee === 7040` |
| a `0`-price program | `fee === 0`, `net === 0`, no divide-by-zero, no `NaN` |

**Caught:** the incidence reversal — fee added *on top* of the parent's price
rather than deducted from the coach's proceeds. That is a public-facing pricing
lie, decided at `docs/decisions/2026-08-10-fee-incidence.md` and cited in the
source comment at `sporve-web.host.html:3141-3142`.

### F3 — **a live defect this suite should pin, not paper over**

Two code paths compute the same fee in **different units**:

- Host, whole dollars: `Math.round(p.price * FEE_RATE)` at
  `sporve-web.host.html:4580`, `:5219`, `:5603`, `:5615-5616`, `:5823`,
  rendered through `const money = n => "$" + Number(n).toLocaleString("en-US")`
  (`:3305`) — **no fraction digits**.
- Module, integer cents: `feeOn(cents)` at `mod-payments.js:141`, rendered
  through `usd()` (`:136-140`) at **two decimals**.

For an $80 booking the host prints `$10` (`Math.round(80 × 0.12) = 10`) and the
wallet prints `$9.60`. The same coach sees a 40¢ discrepancy between the payout
screen and the ledger.

**Test both, assert the current values, and mark the test
`// KNOWN DIVERGENCE — see docs/roadmap/01-unit-tests.md §F3`.** Do not "fix"
it inside a test-writing pass; it is a product decision about which unit is
canonical, and it touches money.

*Not verified:* whether both figures are reachable for the same booking in one
session. The line numbers and the arithmetic are verified; the user journey is
not. Someone should confirm before this is ranked as a bug rather than a smell.

---

## 4. Priority 2 — refund bands (blast radius: cash returned to a parent)

**Function:** `function bandFor(policy, hours)`, `src/mod-payments.js:220-223`:

```js
for (const band of policy.bands) if (hours >= band.minHours) return band;
return policy.bands[policy.bands.length - 1];
```

**Data:** `POLICIES`, `src/mod-payments.js:57-79` — `flexible` (`≥24h → 100`,
else `0`), `moderate` (`≥72h → 100`, else `50`), `strict` (`≥168h → 50`, else
`0`).

| Case | Expected | What it catches |
|---|---|---|
| `bandFor(flexible, 24)` | `pct === 100` | Boundary is **inclusive** (`>=`). An off-by-one to `>` denies a full refund to every parent cancelling at exactly the stated deadline. |
| `bandFor(flexible, 23.99)` | `pct === 0` | The other side of the same boundary. |
| `bandFor(strict, 168)` / `bandFor(strict, 167)` | `50` / `0` | **Strict's top band is 50, never 100.** Catches a "simplification" that assumes the first band of every policy is a full refund. |
| `bandFor(moderate, -5)` | `pct === 50` | The sharp one. A negative `hours` means the session already started, and `bandFor` alone returns **50%** — correctness depends entirely on the caller's `past ?` guard at `mod-payments.js:591` and `:695`. Delete that guard and every already-started moderate booking silently refunds half. This is the mirror of the bug named at `sporve-web.host.html:3134` ("every cancellation refunded 0%"). |
| `bandFor(p, 0)` for all three | `flexible 0`, `moderate 50`, `strict 0` | Pins the fallback row for each ladder. |

### R1 — refund incidence, `pctOf`

**Function:** `const pctOf = (cents, pct) => Math.round(cents * pct / 100);`
— `src/mod-payments.js:142`. Callers: `refundGross` `:598`/`:699`, `refundFee`
`:599`/`:700`.

| Case | Expected | What it catches |
|---|---|---|
| `gross 8000`, `fee 960`, `pct 100` | `refundGross 8000`, `refundFee 960`, so `refundGross - refundFee === gross - fee === 7040` | On a full refund Sporve returns its 12% too — the coach is made whole, not left paying a fee on a cancelled session. |
| same, `pct 50` | `4000` / `480`; coach out-of-pocket `3520 === net/2` | Sporve's share scales with the refund; it never keeps a larger slice of a partial. |
| `gross 8333`, `fee 1000`, `pct 50` | `4167` / `500`; assert `Math.abs(3667 - 7333/2) <= 1` | Rounding on an odd basis must stay within one cent. A larger drift means someone changed the order of operations. |
| `byCredit` charge, `pct 100` | `refundFee === 0` (`:599` short-circuits on `byCredit`) and no cash movement (`:709`) | A full-refund band on a credit returns the credit itself. Refunding cash *and* restoring the credit is double payment. |
| `ch.fee == null` | `refundFee === 0`, no `NaN` | A legacy charge without a fee column must not produce `NaN` in a ledger row. |

---

## 5. Priority 3 — `resolveGroup` (blast radius: a broadcast to the wrong families)

**Functions:** `cmdNorm`, `src/sporve-web.host.html:8615-8620`; `resolveGroup`,
`:8627-8645`. Consumer: `applyAction`'s `send_group_message` branch, `:8683-8700`.

Seed `host.S.conversations` per case, then call `host.resolveGroup(input)`.

| `S.conversations` (all `kind:"group"` unless noted) | Input | Expected | What it catches |
|---|---|---|---|
| `["Monday at noon"]` | `"monday noon"` | `{group}` matching `"Monday at noon"` | `cmdNorm` drops the filler list `["at","the","a","an","on","of","group","chat"]` (`:8619`) from **both** sides. Shortening that list breaks every natural phrasing a coach uses. |
| `["U10 Girls", "U10 Boys"]` | `"u10"` | `{ambiguous: [both]}`, `hit.group` undefined | The partial branch (`:8638-8641`) must **not** return the first match. Returning one sends a roster broadcast to the wrong families — the exact harm the comment at `:8623-8626` names. |
| `["U10", "U10 Girls"]` | `"u10"` | `{group}` = `"U10"`, **not** ambiguous | Exact beats partial (`:8633-8635` runs before `:8637`). Collapsing the two tiers would make every prefix-named group unaddressable. |
| `["Monday"]` | `""` or `"the group"` | `{}` | `cmdNorm` reduces both to `""`, and `if(!want) return {}` (`:8629`) fires. **Remove that guard and `have.includes("")` is true for every group** — an empty target would match the entire roster. Highest-value single case in this file. |
| `["Monday"]` | `"Tuesday"` | `{}` | The no-match branch (`:8644`). |
| `[{name:"Monday", kind:"direct"}]` | `"monday"` | `{}` | Direct threads are filtered out at `:8631`. A filter regression lets a coach broadcast into a single family's 1:1 thread. |

---

## 6. Priority 4 — `loadState` (blast radius: prototype pollution, lost work, a resurrected broadcast)

**Function:** `function loadState()`, `src/sporve-web.host.html:8848-8880`.
Companions: `saveState` `:8841`, `EPHEMERAL` `:8835-8839`, `PERSIST_KEY` `:8834`.
`S` is declared at `:3225`.

Each case: fresh `loadHost()`, write the payload into the stubbed
`sessionStorage`, call `loadState()`, assert on `S` and on storage.

| Payload in `sessionStorage["sporve:state:v1"]` | Expected | What it catches |
|---|---|---|
| *(absent)* | returns `false`, `S` unchanged | `:8851`. |
| `{"portal":"coach"}` | returns `true`, `S.portal === "coach"` | The happy path. `smoke.sh:272-336` covers this in a browser; here it costs 2ms. |
| `'{"__proto__":{"PWN":1},"portal":"coach"}'` **as a raw string** | `Object.getPrototypeOf(S) === Object.prototype`, `S.PWN === undefined`, `S.portal === "coach"` | Prototype pollution. `JSON.parse` makes `__proto__` an *own* property, so it survives `Object.keys`; driving the loop from `Object.keys(S)` (`:8870`) is what closes it. The payload **must** be a raw JSON string — an object literal `{__proto__:{...}}` sets the prototype instead of creating an own key and `JSON.stringify` drops it, making the test vacuous. `smoke.sh:308-311` records that this exact mistake let the test pass against a knowingly vulnerable loader. |
| `'{"constructor":{"x":1}}'` | `S.constructor === Object` | **Beyond what `smoke.sh` checks.** `constructor` is inherited, not own, so `Object.keys(S)` never offers it. Guards the same hole through a second door. |
| `'{"__evil":1}'` | `("__evil" in S) === false` | Merge-never-replace (`:8871`). A foreign key cannot widen `S` with state no code expects. |
| `{"bookings":{"a":1}}` (S.bookings is an array) | `Array.isArray(S.bookings)` still true, object not assigned | The `kind()` type guard `:8869/:8872`. Without it, `S.bookings.map` throws across the app — the failure mode described at `:8865-8868`. |
| `{"auth":null}` (S.auth is an object) | `S.auth` unchanged | `kind()` returns `"null"` for `null` specifically (`:8869`), closing the `typeof null === "object"` hole. A naive `typeof` comparison passes this payload through and produces `S.auth.status` → TypeError. |
| `{"cmdPending":{"body":"MUST NOT SURVIVE"}}` | `S.cmdPending` unchanged | `EPHEMERAL` skip at `:8871`. `cmdPending` is an **unapproved broadcast to every family on a roster** (`:8828-8830`); resurrecting it after a reload sends a message the coach never confirmed. |
| `'{oops'` | returns `false` **and** `sessionStorage.getItem(PERSIST_KEY) === null` | The `catch` at `:8877-8879` must clear the entry. Leaving a poison snapshot means every subsequent load fails forever. |
| `'[1,2,3]'` | returns `false`, `S` unchanged | The `Array.isArray` rejection at `:8855`. |
| round trip: mutate `S`, `saveState()`, mutate again, `loadState()` | value restored, **and** no `EPHEMERAL` key appears in the written JSON | Both directions of the exclusion (`:8841-8846`). |

---

## 7. Wiring

### `src/smoke.sh`

New section **first**, above `── build ──` (`smoke.sh:29`). Unit tests need no
build and no browser, so they should fail in ~2s rather than after a 60s browser
run. Follow the file's own doctrine at `smoke.sh:57-60` — **fail, never skip**,
when the runner is missing:

```bash
echo "── unit ────────────────────────────────────────────"
if command -v node >/dev/null 2>&1; then
  if node --test test/*.test.mjs >/tmp/smoke-unit.txt 2>&1; then
    pass "unit: $(grep -c '^ok ' /tmp/smoke-unit.txt) assertions"
  else
    fail "unit tests failed:"; sed 's/^/        /' /tmp/smoke-unit.txt
  fi
else
  fail "unit: node missing — the fee, refund, and state guards cannot run"
fi
```

### `.github/workflows/pr-checks.yml`

No change required. `node-version: "22"` is already set (`:27-28`) and
`bash src/smoke.sh` (`:48`) picks the new section up. Optionally add a separate
`- name: Unit` step *before* Playwright install so a fee-math failure reports in
20s instead of 4 minutes.

### `package.json`

Add a `scripts` field only — it introduces **no dependency**, so the Vercel
install graph is byte-identical:

```json
"scripts": { "test": "node --test test/*.test.mjs" }
```

Use the explicit glob, not `node --test test/`; directory recursion semantics
shifted across Node majors and the glob is stable on 22 and 24.

### Deployment hygiene

`vercel.json` sets headers only — no `outputDirectory`, so `test/` would be
uploaded (a few KB, never served, no CSP impact since nothing links it). Adding
`test` to `.vercelignore` is tidy and optional. *Not verified:* whether a
`.vercelignore` already exists.

---

## 8. Order of implementation

1. `test/_scope.mjs` + `test/fee.test.mjs` F0 and F1 only. This proves the whole
   access mechanism against the highest-value assertion in the repo. If the
   loader does not work, it fails here, cheaply.
2. Rest of §3, then §4 (money paths, both).
3. §6 `loadState` (security surface).
4. §5 `resolveGroup`.
5. Wire into `smoke.sh`, run it, confirm exit 0.

Roughly 35 assertions across four files. All of §3–§6 is `node:assert/strict`
and `node:test` — nothing else.

---

## 9. What this deliberately does not do

- It does not replace or weaken one existing `smoke.sh` assertion. Rendering,
  contrast, overflow, and the type scale stay browser-verified.
- It does not test any module's `views`/`modals`/`wire` exports. Those build
  HTML strings; asserting on them pins markup and turns every restyle into a red
  test. Out of scope, permanently.
- It does not touch `~/SportsMan-main`. Server-side fee and RLS behaviour is a
  different surface with a different harness.

---

## Five-sentence technical reading

**What changed:** nothing executable — this is a specification for a
`node:test` suite that reaches four unexported functions (`feeOn`, `bandFor`,
`resolveGroup`, `loadState`) without editing a line of product code.
**The mechanism:** a loader reads the source *text*, appends a `return { ... }`
epilogue so values trapped in a closure or a classic-script global become the
result of an expression, and evaluates it in a `node:vm` context — a sandboxed
JavaScript realm with its own globals — carrying a ~40-line browser stub, then
copies the host's real `FEE_PCT` onto that context so module code resolves the
genuine constant through its scope chain rather than a test fixture.
**Downstream:** it adds a `test/` directory, one `scripts` entry in
`package.json` (no dependency, so Vercel's install is unchanged), and a new
first section in `src/smoke.sh` that CI picks up for free on Node 22.
**What breaks it:** any refactor that splits the host into a third `<script>`
block, renames the `bootModules();` boot call, or converts a module away from a
single top-level IIFE — each is asserted by the loader, so it throws instead of
passing vacuously, which is the intended failure mode.
**Verification:** every file:line in this document was read at commit `e373fda`;
the three structural assumptions were checked by `rg` (two `<script>` opens,
`bootModules` at `:6154`/`:8890`/`:8893`, six top-level browser statements), and
the one claim I could not verify — whether the `$10` and `$9.60` renderings in
§F3 are reachable for the same booking in one session — is flagged as unverified
in place rather than asserted.
