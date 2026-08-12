# Coach signup and listing setup — flow spec

**Status:** authored 2026-08-11, not implemented. Supersedes nothing; extends
`mod-coachonboard.js`.
**Owner brief:** Airbnb's "Become a host" flow — a modal whose contents morph in
place through auth, then a real page navigation into a listing wizard whose
headline changes per step.
**Convention note:** filed in `docs/` rather than as a root `*-SPEC.md`. Root
`LANDING-SPEC.md` / `SUBPAGES-SPEC.md` / `IMAGE-BRIEF.md` are the Aug 4–5
page-restyle briefs. `docs/` is where the working specs and adjudications have
lived since Aug 9 (`docs/coach-portal-spec.md`, `docs/decisions/*`). This is a
flow spec for a coach surface, so it follows the newer convention.

Every claim about current behaviour below carries a `file:line`. Verify before
building; the file moves.

---

## 0. What is actually true today

### 0.1 There are four competing signup surfaces, not one

| # | Surface | Where | What it does |
|---|---|---|---|
| 1 | `authsheet` modal | `src/sporve-web.host.html:5745-5768` | Single field: "Phone number or email" + Continue, Google, Apple. |
| 2 | `onboard` 3-step modal | `src/sporve-web.host.html:5994-6033` | Step 0 role picker → step 1 sport picker → step 2 account form. |
| 3 | `coachgate` full route | `src/sporve-web.host.html:7562-7604` | Airbnb-style split: login/signup left, "Welcome to Sporve" panel right. Renders full-screen; `render()` omits topbar/footer for this route (`:7618`). |
| 4 | `mod-coachonboard` 7-step wizard | `src/mod-coachonboard.js:38-46`, exported at `:1107-1113` | Identity, Sports, Services, Pricing, Availability, Background check, Review. |

Surfaces 2 and 4 **both** collect sports, into **two different state keys**:
`S.onboardSports` (`:3276`, written at `:8230`) and `S.onboard.sports`
(`mod-coachonboard.js:143`). Nothing copies one into the other. A coach who
picks Soccer in the modal picks it again in the wizard.

Surfaces 2 and 4 also **collide on the name `onboard`**. `S.modal={type:"onboard"}`
resolves to the 3-step host modal (`:5994`); `modView("onboard")` resolves to the
7-step module wizard (`mod-coachonboard.js:1109`). `startCoachOnboarding()` uses
both in adjacent lines:

```
src/sporve-web.host.html:7556-7561
function startCoachOnboarding(){
  S.portal="coach";S.signupRole="coach";
  if(!isVerified()){S.onboardStep=0;S.modal={type:"onboard"};}   // 3-step modal
  else {S.coachTab=modView("onboard")?"onboard":"dashboard";}     // 7-step wizard
  S.route={name:"dashboard",arg:null};window.scrollTo(0,0);render();
}
```

So a **guest gets the 3-step modal and a verified user gets the 7-step wizard.**
That is the shape of `HANDOFF.md:178` finding #7 — but that finding is now
**partly stale** and must not be quoted as-is:

- Stale: "`data-becomecoach` branches on `isVerified()`". It no longer does.
  `src/sporve-web.host.html:7989-7992` sends every `data-becomecoach` click to
  the `coachgate` route unconditionally.
- Stale: "The 7-step wizard has no rail entry … and no way back once you leave."
  It is reachable three ways now — as a route via `render()`'s
  `modView(r.name)` fallback (`:7640`), as a coach tab via `coachBody()`'s
  `modView(t)` fallback (`:5349`), and from `startCoachOnboarding()` (`:7559`).
  It has a `data-cob-dash` escape back to the dashboard
  (`mod-coachonboard.js:1028-1032`).
- Still true: `mod-coachonboard.js` exports no `tabs:{}` (`:1107-1113`), so the
  wizard never appears in the coach rail as a labelled destination. It is
  reachable only if something sets `S.coachTab="onboard"`.

### 0.2 The wizard is good and it is nearly complete

`mod-coachonboard.js` is 1115 lines with per-step validators
(`:167-302`), a gated rail that will not let you skip forward past an unfinished
step (`reachable()` / `goStep()` at `:296-307`, `:1004-1011`), and in-place
repaint so a re-render cannot eat a keystroke (`sync()` at `:952-1001`). Its
central invariant is stated at `:8-13` and enforced with no branch that can
violate it — the submit path writes `status:"pending"`, `verification:"unverified"`,
`backgroundCheck:"pending"`, `verified:false`, `visible:false`, `bookable:false`
(`:889-933`).

Drafts are deliberately **not** pushed into `PROGRAMS` or `S.listings`
(`:908-911`), which is what makes a new coach structurally unsearchable and
unbookable rather than merely flagged.

### 0.3 The wizard does not collect what a listing actually renders

A listing is a row of `RAW` mapped through `K` (`src/sporve-web.host.html:3073-3086`):

```
const K=["id","biz","verified","sport","title","desc","price","model","rating",
         "reviews","lng","lat","featured","skill","ageGroup","minAge","maxAge",
         "cap","enrolled"];
```

plus derived `img`, `gallery`, `whatsIncluded`, `address`, `cancellationPolicy`
(`:3077-3084`).

The wizard's draft listing (`mod-coachonboard.js:913-933`) supplies
`id, providerId, biz, title, sport, sports, format, cap, enrolled, minutes,
price, model, netPerSale, availability, status, published, visible, bookable,
verified, createdAt`.

**Missing, and therefore un-renderable if a draft were ever published:**
`desc`, `skill`, `ageGroup`, `minAge`, `maxAge`, `lng`, `lat`, `img`/`gallery`,
`address`, `whatsIncluded`, `cancellationPolicy`.

`desc`, `skill` and the age range are the three a family reads first — they
drive the card body, the filter chips and the age match. Their absence is the
real hole the owner's brief found.

### 0.4 Nothing persists to a server; the draft does survive a reload

There is no Supabase client and no write endpoint in this repo. The only
`fetch` is `/api/ai` (`src/sporve-web.host.html:8648`).

State persists to **sessionStorage**, not localStorage, deliberately
(`:8807-8809`), under `sporve:state:v1` (`:8827`), merging only keys `S` already
has (`:8848`). `modal` is in the `EPHEMERAL` exclusion set (`:8829`).

Consequence that decides the modal/page split below: **`S.onboard` survives a
reload; `S.modal` does not.**

### 0.5 Backend reality

`docs/gaps.md` Tier 1 #1: production Supabase `tseszaprvtvqrkfpditu` is applied
only through migration `20260725033343`. Per the brief's own grounding, prod has
`providers`, `programs`, `sessions`, `bookings`, `profiles`, and has **no
`services` table, no `availability` table, no `provider_safety_cleared()`**.

The wizard's `services[]` array and its `availability` object therefore have **no
destination table in production**. Any spec that says "persists to Supabase"
without saying that is lying.

---

## 1. Decisions

> ### Owner sign-off — 2026-08-11
>
> All four open questions were put to the owner and answered. This section is no
> longer advisory; it is settled and the implementer follows it.
>
> 1. **Retire the 3-step `onboard` modal** (`src/sporve-web.host.html:5994-6033`).
>    Approved. This lifts the "flagged, not performed" hold in D2 below — the
>    source edit is now authorised. It also removes the `isVerified()` fork at
>    `:7558-7559`, so guest and signed-in users get the same wizard.
> 2. **The five new listing fields are collected inside the wizard's Services
>    step**, not on a post-approval screen. The draft is complete at submit.
> 3. **No standalone commitment step in auth.** The "every coach clears their own
>    check" promise folds into the wizard's existing background-check step
>    (step 6), where the thing that enforces it already lives. Auth stays at two
>    screens, not three — supersedes any A2 screen described in §2.
> 4. **`address` is collected now and geocoded later.** Store the string; leave
>    `lng`/`lat` null until a server-side geocoder exists. A draft has no map pin
>    in the meantime, which is acceptable because drafts are not mapped anyway.

### D1 — Modal for auth, page for the wizard. Confirmed, for a mechanical reason.

The owner's instinct matches the storage model, not just Airbnb. `S.modal` is
ephemeral and dropped on reload (`:8829`); `S.onboard` is persisted (`:8834-8838`).
Auth is thirty seconds of disposable input and belongs in the thing that
evaporates. The wizard is twenty minutes of a coach's business description and
belongs in the thing that survives.

"A real page" in this app means `S.route={name:"onboard"}`, rendered full-screen
by `render()`'s `modView(r.name)` branch (`:7640`) — the same mechanism
`coachgate` already uses to drop chrome (`:7618`). No new routing primitive is
needed.

### D2 — Extend `mod-coachonboard.js`. Do not replace it, and delete its rival.

Rebuild cost is high (1115 lines of validated, gated, repaint-safe wizard) and
the delta is small (three field groups). Replace is not on the table.

The change that matters is the other direction: the **3-step `onboard` modal at
`src/sporve-web.host.html:5994-6033` is dead weight and must be retired.** It
duplicates the sport picker, asks the role question the codebase already decided
never to ask (`:5720-5722` — "Role is inferred from where you came from, never
asked"), and writes to a state key nothing downstream reads for coaches.

**This requires a source edit and is therefore out of scope for this document.**
Flagged, not performed.

### D3 — The field set, and what a coach cannot supply

**Coach supplies (already collected):** `legalName`, `businessName`, `phone`,
`city`, `region`, `years`, `sports[]`, and per service `name`, `format`,
`capacity`, `minutes`, `price`, `model`, plus `days[]`, `startTime`, `endTime`,
`consent`, `dob`, `ssn4` (`mod-coachonboard.js:140-148`).

**Coach supplies (to be added):** per service `desc`, `skill`, `minAge`,
`maxAge`; per provider `address`.

**Coach cannot supply — must be server-set or derived, and no input may exist
for any of them:**

| Field | Why not |
|---|---|
| `verified` | Trust claim. Written `false` by the submit path (`:931`) with no branch that can produce `true`. |
| `rating`, `reviews` | Earned from completed bookings. A coach typing their own rating is fraud. |
| `featured` | Commercial/editorial placement, platform-set. |
| `enrolled` | Derived from bookings; the wizard hardcodes `0` (`:919`). |
| `ageGroup` | **Derive from `minAge`/`maxAge`**, never ask. Two sources for one fact is how they disagree. |
| `lng`, `lat` | Requires geocoding. There is no geocoder in a single static file under `default-src 'self'`. |
| `id`, `providerId`, `createdAt`, `netPerSale` | Generated (`:889`, `:914-915`, `:925`). |
| `status`, `published`, `visible`, `bookable` | The lock (`:926-932`). |

**Honest consequence to state in the UI:** because `lng`/`lat` cannot be
collected client-side, a draft listing has no map pin and could not appear in map
search even after approval. Geocoding the `address` is a backend job.

### D4 — The transforming headline is load-bearing, not decorative

It is the only orientation cue that survives a scroll. The wizard's rail
(`mod-coachonboard.js:403-417`) is `position:relative` in a left column and
scrolls away on narrow viewports (`:391`), and the current header prints a
generic "Coach onboarding · step N of 7" eyebrow with the step title beneath
(`:812-814`). A headline that names the *task* rather than the *step number*
tells a coach what this screen wants without reading the fields.

Rule: the h1 changes per step, the eyebrow keeps the step counter. Both, not one.

### D5 — Auth ends the moment identity exists; onboarding begins at business facts

The boundary is `completeAuth()` (`src/sporve-web.host.html:3357`), which sets
`S.auth={status:"verified",user}` and runs `S.pendingIntent`.

Note the vocabulary trap: `isVerified()` (`:3303`) means **"is signed in"**, not
"is background-checked". A provider created by the wizard is signed in and
`verified:false` at the same time (`mod-coachonboard.js:931`). These are two
different `verified`s and the spec below never uses the bare word.

So: **auth owns name, contact, password, consent-to-terms. Onboarding owns
everything a family would read.** Legal name is the one field that looks like
auth and is not — it goes to the screening partner
(`mod-coachonboard.js:39`), so it stays in wizard step 1 where its purpose can be
explained next to it.

---

## 2. The flow

### Phase A — the morphing auth modal

Entry: any `[data-becomecoach]` control. Today that routes to `coachgate`
(`src/sporve-web.host.html:7989-7992`). **Keep `coachgate`** — it is the marketing
split-screen and it already carries the Google/Apple buttons
(`:7580-7583`). Phase A is what happens *after* the coachgate form submits
(`#cgForm`, `:7994`) with an email or phone.

One modal shell. One state key. Contents swap; the card does not move.

```
S.authFlow = {
  step: 0,                 // 0..2
  identifier: "",          // carried from #cgForm / authsheet
  first: "", last: "",
  dob: "",
  agreed: false,
  intent: "coach"          // set by the entry point, never asked
}
```

`authFlow` must be added to `EPHEMERAL` (`:8828-8832`) alongside `modal` — a
half-typed date of birth should not survive a reload.

| Step | h1 | Sub | Fields | Back button |
|---|---|---|---|---|
| A0 | Log in or sign up. | Coach on Sporve — set availability, take bookings, get paid. | identifier (existing, `:5751-5758`) | closes the modal |
| A1 | Create your account. | This is the name that goes on your background check. | First name, Last name, Date of birth, Email (prefilled from `identifier`, read-only when it is an email) | → A0 |
| A2 | Every coach clears their own check. | Sporve lists people, not logos. Your listings stay drafts until your check comes back. | Agree and continue (primary) · Not now (text button) | → A1 |

A2 is our analogue of Airbnb's Community Commitment, and it is the honest one for
this product: it states the trust rule at the moment the coach opts into it,
before they have invested twenty minutes in a wizard.

"Not now" dismisses to the family portal. It does **not** create a provider.

On A2 agree: call `completeAuth({...})` (`:3357`) with `role:"provider"`, then
`go("onboard")`. The modal closes. That is the last modal in the flow.

**Copy law check:** every h1 above is sentence case, ≤7 words, ends with a
period. Every sub is ≤22 words.

### Phase B — the full-page wizard

Route: `S.route={name:"onboard"}`, rendered by `:7640`. Chrome dropped the same
way `coachgate` drops it (`:7618`) — logo top-left, no nav, no footer.

Steps stay at seven. The new fields fold into existing steps rather than
inflating the count.

| # | Step (`STEPS[i][0]`) | New h1 per step | Change |
|---|---|---|---|
| 1 | Identity | Set up your coaching business. | **+ `address`** (street, city, region already at `:142`) |
| 2 | Sports | Pick the sports you coach. | none |
| 3 | Services | Name what a family books. | **+ per service: `desc`, `skill`, `minAge`, `maxAge`** |
| 4 | Pricing | Set your price per service. | none |
| 5 | Availability | Say when you can coach. | none |
| 6 | Background check | Every coach clears their own check. | none |
| 7 | Review | Read it back before submitting. | show the new fields |

The h1 replaces the current step title render at `mod-coachonboard.js:808-814`.
Keep the eyebrow `Coach onboarding · step N of 7` (`:812`) — it is the counter,
the h1 is the task.

### 2.1 New fields — exact definitions and validation

Added to `newService()` (`mod-coachonboard.js:132-139`) and to `BLANK.services[0]`
(`:144`), which must be kept in sync or a first-run draft differs in shape from an
added one.

| Field | Type | Control | Validation (returns the first genuine problem, per `:167-171`) |
|---|---|---|---|
| `desc` | string | textarea, 3 rows | Required. ≥40 chars, ≤280. Message: "Tell a family what happens in a session — at least a sentence." |
| `skill` | enum | select | Required. Values exactly `Beginner`, `Intermediate`, `Advanced`, `All Levels` — must match the `RAW` vocabulary at `:3041-3054` or filters break. |
| `minAge` | int | number input | Required. 3–80. |
| `maxAge` | int | number input | Required. 3–80 and `>= minAge`. Message: "The oldest age can't be below the youngest." |
| `address` | string | text input, on step 1 | Required. ≥8 chars. Sub-label states plainly: "Used for distance in search. Your exact address is never shown to families." |

`ageGroup` is **derived at submit**, not entered:

```
maxAge <= 12            -> "Youth (Under 12)"
maxAge <= 16            -> "Juniors (Under 16)"
minAge >= 13            -> "Teens (13-18)"
otherwise               -> "All Ages"
```

Those four strings are the complete set present in `RAW` (`:3041-3054`). Emitting
a fifth would create a filter value nothing matches.

### 2.2 Submit

`submitApplication()` (`mod-coachonboard.js:~885-945`) gains the new keys in the
`d.drafts` map (`:913-933`) and `address` in `d.profile` (`:889-906`). Everything
in the D3 "cannot supply" table stays exactly as it is written today. The drafts
must remain outside `PROGRAMS` and `S.listings` (`:908-911`) — that is the lock,
and no part of this spec touches it.

`lng`/`lat` are written `null`, with a comment saying geocoding is a backend job.

---

## 3. What persists where

| Thing | Today | After this spec |
|---|---|---|
| `S.authFlow` | n/a | in-memory only; added to `EPHEMERAL` (`:8828`) |
| `S.onboard` draft | sessionStorage `sporve:state:v1` (`:8827`) | unchanged |
| Provider profile | `S.onboard.profile`, in-memory (`:889`) | unchanged |
| Draft listings | `S.onboard.drafts`, in-memory (`:913`) | unchanged |
| Anything on a server | **nothing** | **nothing** |

**Backend truth, stated so nobody builds on a wrong premise:** production
Supabase is applied through `20260725033343` (`docs/gaps.md` Tier 1 #1). It has
`providers`, `programs`, `sessions`, `bookings`, `profiles`. It has **no
`services` table and no `availability` table.** The wizard's `services[]` and
`availability{}` have nowhere to land. Persisting this flow for real requires
those two tables plus their RLS policies to ship first, and per the hard rule in
`docs/gaps.md` #1 that must be a per-object apply in the SQL editor — never
`supabase db push`.

---

## 4. Out of scope

- Photos / `gallery`. `img` is `phShot(sport)` (`:3077`); real upload belongs to
  the media module, and base64-inlining coach photos would bloat the single file.
- `whatsIncluded`, `cancellationPolicy` — hardcoded per-id today (`:3079-3084`).
  Post-approval listing editing, not signup.
- Geocoding `address` → `lng`/`lat`.
- Any Supabase write.
- Retiring the 3-step `onboard` modal (`:5994-6033`) — required, but it is a
  source edit and this is a spec.
- Apple sign-in — currently a toast (`:7999`).

---

## 5. House-contract compliance for the implementer

- Type: tokens only, no px font-sizes. The wizard's own CSS already uses
  `var(--text-base)` / `var(--text-xs)` (`mod-coachonboard.js:324-326`) — match it.
- Colour: no new hex. Sport colour only on the sport chips, which already use
  `--sc` (`:1082-1086`).
- Register: this flow is about money, consent and screening, so it takes
  `reg-serious` (Hanken Grotesk) per `CLAUDE.md` §4. Note `CLAUDE.md` §4 was
  updated 2026-08-09 — the default pair is now Instrument Serif + Inter, not the
  older Syne + Plus Jakarta.
- Icons: `PICON` only. No emoji.
- Verify with `bash src/smoke.sh` (exit 0), which asserts every rendered font
  size sits on the 8-step scale.
- Do not run `src/build.py` when another agent is active.
