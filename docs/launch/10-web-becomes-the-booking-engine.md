# the-sporve-web becomes the booking engine — reanalysis

Owner decision, 2026-08-11: **`the-sporve-web.vercel.app` becomes the booking
engine entirely.** The Airbnb model — the website is where families search, book
and pay; the Flutter app is the other client, not the only real one.

This invalidates the framing I worked under for most of that session, in which
this repo was "the marketing/demo surface" and `SportsMan-main` was "the real
product." Everything below is scoped from the corrected premise.

---

## 1. What this site is today, measured

| fact | value |
|---|---|
| source lines | **20,269** (9,432 host + 10,837 across 10 modules) |
| built artifact | single `index.html`, ~1.85 MB, fonts and hero images base64'd in |
| backend routes | **one** — `/api/ai` |
| Supabase client | **none** |
| auth | `S.auth = {status:"guest"|"verified"}` — a mock, no identity |
| data source | `SEED` object, deep-cloned into `S` at boot |
| seeded collections | **10** — athletes, bookings, conversations, messages, notifications, parentUpdates, providerProfile, teams, trainers, user |
| listings | a `COMPANIES` constant |
| reads of `S.*` across the codebase | **747**, across **73 distinct keys** |
| persistence | `sessionStorage`, versioned, merge-not-replace |

## 2. The blocker nobody would predict from reading the code

```
Content-Security-Policy: default-src 'self'; connect-src 'self'; …
```

**The page is currently forbidden from making a network request to any origin
but its own.** Not "hasn't been wired up" — actively blocked by a header this
repo ships deliberately, with per-script sha256 hashes and no `unsafe-inline`.

Nothing else on this list matters until `connect-src` admits the Supabase
origin. It is a one-line change to `vercel.json` and it is the single highest
-leverage edit in the whole plan, because every subsequent step is untestable
without it.

**Do not widen it to `*`.** Add exactly:

```
connect-src 'self' https://tseszaprvtvqrkfpditu.supabase.co
```

## 3. The architecture is better suited to this than it looks

747 reads of `S` sounds like a rewrite. It is not, because of one property:
**every render path reads from a single in-memory object `S`, and `render()`
re-derives the DOM from it.** That is already the shape a data-driven app wants.

The migration is therefore **not** "rewrite 747 call sites". It is:

1. replace `SEED` hydration with an async load into the same `S` keys
2. replace local mutations with a write that round-trips through the server
3. leave the 747 reads alone

The render layer never learns where the data came from. That is the whole
strategy, and it is only available because the previous work kept state in one
place.

## 4. Recommendation: PostgREST over the Supabase JS SDK

Bundling `@supabase/supabase-js` costs ~40 KB minified, adds a script that
`build.py` must hash into the CSP, and pulls a dependency into a repo that
currently has **zero** runtime dependencies and inlines everything.

Supabase's REST surface is plain HTTP:

- **data** — `GET /rest/v1/programs?select=…` with `apikey` + `Authorization`
- **auth** — `POST /auth/v1/token?grant_type=password`, `/auth/v1/signup`
- **RPC** — `POST /rest/v1/rpc/search_listings`
- **functions** — `POST /functions/v1/stripe-create-checkout`

All reachable with `fetch`. RLS, the consent gate and the background-check gate
apply identically — they live in the database, not the client. A ~120-line
`mod-api.js` replaces the SDK entirely and keeps the single-file, zero-dependency
architecture intact.

**This is a recommendation, not a decision made.** The SDK buys realtime
subscriptions and token refresh; if messaging needs live updates, revisit.

## 5. What must be built, in dependency order

### Phase A — connectivity (nothing works before this)
- A1 `connect-src` admits the Supabase origin
- A2 `mod-api.js`: fetch wrapper, anon key, error normalisation
- A3 smoke assertion: the built page can reach PostgREST and gets a 200

### Phase B — identity
- B1 real signup/login against GoTrue; replace the `S.auth` mock
- B2 session persistence + refresh (access tokens expire in 1h)
- B3 `handle_new_user` creates the profile row — already live in production
- B4 role routing from `profiles.role`, not from a client guess

### Phase C — read paths
- C1 browse grid from `programs` + `providers` — replaces `COMPANIES`
- C2 search via the `search_listings` RPC (already gated on background checks)
- C3 provider detail
- C4 the seven owner-scoped collections behind auth

**Note:** `providers` exposes only public-safe columns to `anon` — exact
coordinates, `stripe_account_id` and `owner_id` are revoked. Use
`public_latitude` / `public_longitude` for map pins.

### Phase D — the booking write path `[CRITICAL-PATH]`
- D1 athlete creation **through the consent gate** — `parent_consent`,
  `consent_at` and `consent_version` are all required or the insert raises
- D2 booking insert — three triggers fire: consent, background-check, capacity
- D3 `stripe-create-checkout` with `successUrl`/`cancelUrl` on **this** origin
- D4 return handler reading `payment_status` after redirect
- D5 the webhook already exists and is idempotent; no work

### Phase E — parity
- E1 messaging, E2 reviews (double-blind, now live), E3 notifications,
  E4 the coach portal against real data

## 6. Sequencing risk, stated plainly

The site currently **works** — it renders, it is fast, it has 27 passing smoke
assertions, and it ships a real CSP. Every step above trades some of that
certainty for capability.

The mitigation is that `S` is one object: a collection can be migrated from
`SEED` to live data **one key at a time**, with the rest of the page untouched.
Do not attempt a big-bang switch.

`smoke.sh` will need a live-data mode or it will fail the moment `SEED` stops
being the source of truth.

## 7. Honest estimate

Phase A is hours. B and C are the bulk. D is small in code and the highest risk
in consequence. E is long but parallelisable.

**The backend is not the constraint.** As of 2026-08-11 production has the
consent gate, the background-check gate, column privacy, one flat 12% fee, an
idempotent webhook, 25 asserted invariants and bookable inventory. Every guard
this site will need is already enforced server-side. What is missing is a client
on this origin that speaks to it.
