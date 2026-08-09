# Comprehension gaps — Sporve

Things the owner has not yet closed out. Seeded from an analysis of 170 of his
own messages across four repos over seven days, plus findings from a
seven-subsystem audit. Claude Code references this file and weaves these
topics into debrief questions.

**How to use it:** when you can answer the question in a sentence without
looking, delete the row. When a debrief exposes a new gap, add one.

---

## Tier 1 — you must understand these deeply

These are where a silent bug costs money, safety, or the company.

| # | Gap | The question that closes it |
|---|---|---|
| 1 | **Repo vs production drift** — *live state read 2026-08-06.* The production Supabase project `tseszaprvtvqrkfpditu` is applied only through migration `20260725033343` (18 migrations total). Everything dated after that — the `platform_fees` schedule, RLS availability-gate, capacity, Google-signup fix — is **not in prod**. Now a reconciliation task, not an unknown. | ~~Which migrations are actually applied right now?~~ **Answered: through `20260725033343`.** Remaining: reconcile each authored-not-applied migration before any `db push`. |
| 3 | **RLS is the only thing between one parent and another parent's child.** One `USING (true)` policy exists (`availability_select_public`) — any logged-in user can read every coach's schedule. Its gated replacement is in the not-applied set. | Which tables can a signed-in parent read that belong to someone else? |
| 4 | **Google signup cannot create a coach.** Role goes as an OAuth query param; GoTrue drops it; `handle_new_user` falls to `'searcher'`. Unrecoverable because `prevent_profile_role_change` has no service-role exemption. | If a coach signed up with Google yesterday, what is their role and how would you fix it? |
| 5 | **Capacity is enforced nowhere on the live booking rail.** `enforce_booking_slot_capacity` no-ops when `service_id is null`, which is every booking `addBooking` creates. `enrolled_count` is never incremented. | What stops a session with 12 seats from taking a 13th booking? |
| 6 | **Partial-apply drift — the auth fix went live ahead of its guards** (*pentest 2026-08-07*). `20260806_000100` (role-guard bypass + `claim_provider_role`) was applied to prod today, but its same-batch siblings `000200` (capacity), `000300` (availability IDOR + fail-closed denies) and `000400` (definer EXECUTE) are all **authored, not applied**. So gaps #3 and #5 are confirmed **still live**, and the uniform "nothing after `20260725033343` is in prod" picture in #1 is now stale. The new self-promotion path itself is verified safe (born-unverified, invisible, unbookable), so this is a sequencing risk, not an exploit. | Apply `000200`/`000300`/`000400` in one human-gated pass; then what is the true applied high-water mark, and does any `profiles` UPDATE policy ever admit `anon` (the one assumption that would expose the NULL-uid bypass)? |

## Tier 2 — understand the shape

| # | Gap | The question that closes it |
|---|---|---|
| 6 | **Two matching engines disagree.** SQL `ltad_max_tier` is 0-4; Dart `_ceilingForAge` is 1-3, reading the same `intensity_tier` column. A 10-year-old gets different results in search vs chat. | Which code path decides what a 10-year-old is allowed to see, and does the other agree? |
| 7 | **The "only background-checked coaches" claim is enforced in one path and asserted in the other.** `ai-match` structurally cannot surface an unverified coach; `ai-chat` is a prompt asking the model not to. | Which AI surface could name an unverified coach, and what would stop it? |
| 8 | **Nothing resets on sign-out.** 23 of 24 root providers keep the previous account's roster, finances, children and chat in memory. | On a shared iPad, what does the second person to sign in see? |

## Tier 3 — open decisions, not knowledge gaps

Raised repeatedly across sessions and never resolved. Each needs a sentence,
not a study session.

| # | Open loop | The forcing question |
|---|---|---|
| 9 | Stack identity of `the-sporve-web` | Static `build.py` site or Next.js — which, this month? |
| 10 | Which URL is production | `sporve.vercel.app`, `the-sporve-web.vercel.app`, or `sporve-landing` — which one, and what are the others now? |
| 11 | Session partition | Which directories does the image session own exclusively? |
| 12 | Waitlist deliverability | Has a signup from a fresh address delivered an email in the last 24h — yes or no? |
| 13 | Demo dataset | Ten companies × five listings — final? |
| 14 | Type scale | Is 64px wanted? It is the one step in the requested scale that does not exist here. |

---

## Closed

**2026-08-06 — the five open decisions, answered by the owner.**

| was | answer | what it changes |
|---|---|---|
| 10. Which URL is production | **`the-sporve-web.vercel.app`.** | Confirms what has been deployed to all session. The other two are not production; nothing should be pushed to them without a decision. |
| 9. Stack identity | **Moving to Next.js.** | The largest open decision in the repo, now settled in direction. See the note below — it is a migration, not a switch, and nothing about it is started. |
| 11. Session partition | **Image session owns imagery across the board**, scoped to whichever site is actively being worked on. | Resolves the collision hazard from HANDOFF.md. Imagery = `assets/`. This session stays out of it. |
| 12. Waitlist deliverability | **No email has sent.** | Open BUG, not a gap. Moved to Tier 1 below. |
| 14. Type scale / 64px | **Do not change it arbitrarily — derive the size from evidence.** | Answered by measurement; see `docs/type-evidence.md`. Verdict: keep 52px. |
| 2. Platform fee rate (was Tier 1) | **Flat 12% of every booking. No first/recurring split, no off-platform rate, no other fees.** | Retires the 18/4/2.5 schedule in code (never was live — prod charges the 10% default, coach UI projects 18/4; both wrong). Reconciliation drafted, not applied: `docs/fee-reconciliation.md`. |

### A correction worth stating plainly

Next.js was described as "a type of JavaScript notation/language". It is
neither. JavaScript is the language. **React** is a library for building
interfaces in it, and **Next.js is a framework built on React** that adds
routing, server rendering and a build pipeline. TypeScript is the thing that
is "JavaScript with notation" — a superset that adds type annotations.

This matters practically, not pedantically: the cost of the migration is
almost entirely *React*, not Next.js. Moving to Next.js means rewriting every
one of these template-literal view functions as React components with state
and props. Next.js on top of that is mostly configuration.

---

> **⚠️ CORRECTION 2026-08-07 (post-run): the DB-state claims in this block are
> UNRELIABLE and partly FALSE.** They contradict actions the owner verifiably
> performed this session, so the delta pentest's "live introspection" appears to
> have failed and confabulated:
> - **`000100` IS applied** (this block says it is not). Proof: the owner ran the
>   guard SQL ("Step A succeeded") AND later ran `update profiles set
>   role='provider'` as service-role in the SQL editor, which **succeeded** and
>   left the coach as `provider`. The *old* strict `prevent_profile_role_change`
>   raises on ANY role change; that UPDATE can only succeed if the `auth.uid() IS
>   NULL` service bypass from `000100` is live. Therefore `claim_provider_role`
>   exists and gap **#4/#6 is CLOSED**, not "inverted/still live".
> - The **availability / IDOR** claim is likewise suspect: the owner reported
>   block ① (`create policy … on public.availability`) ran cleanly, which is
>   impossible if the table did not exist. Treat "availability does not exist" as
>   unverified.
> - **Trustworthy from that run:** the **session-race (#16)** — verified
>   independently in code (no session-generation guard in `lib/`), not via DB
>   introspection.
> Tie-breaker to settle it for good, one line in the SQL editor:
> `select proname from pg_proc where proname='claim_provider_role';` → a row = the
> pentest was wrong and `000100` is applied.

## Live-state reconciliation — 2026-08-07 (verified against prod, not files)

The 2026-08-07 delta pentest introspected the live DB (`tseszaprvtvqrkfpditu`)
directly. It **overturns several rows above that were inferred from migration
files** — migration headers ("applied to prod…") and the CLI migration list are
both unreliable here; only DB introspection is authoritative. Kept as an
addendum rather than editing the rows, so the correction is legible:

- **#3 / #5 availability IDOR — NOT live.** `public.availability` does not exist
  in prod; there are **zero** `USING(true)` SELECT policies; every private table
  keys SELECT off `auth.uid()`. The IDOR is latent — it goes live only if the
  repo `services`/`availability` subsystem is pushed with the baseline
  `USING(true)` policy. Gate with `000300` **before** that push.
- **#5 capacity oversell — CLOSED in prod.** `trg_enforce_booking_session_capacity`
  (BEFORE INSERT/UPDATE, per-session advisory xact lock, reject at/over
  `sessions.capacity`) is live and enabled, plus `maintain_program_enrolled_count`.
  `000200` **is** applied.
- **#6 "auth surface ahead of its guards" — inverted / moot.** `000100` is **not**
  applied: `claim_provider_role` is absent and `prevent_profile_role_change` is
  the old strict body (no service bypass, no self-promotion). The guard that IS
  applied is the capacity fix, not the auth surface — so there is no
  auth-ahead-of-guards exposure. (The `000100` self-promotion path was verified
  safe last run regardless.)
- **#1 drift is wider than recorded.** Live CLI remote ids (`20260708000000`…
  `20260725033343`) match **no repo filename** — prod is a separate lineage,
  further edited via the SQL editor.
- **#4 Google-signup role — still live.** `prevent_profile_role_change` has no
  service-role branch, so a mis-roled coach is uncorrectable via a normal UPDATE.

## Tier 1 additions

| # | Gap | The question that closes it |
|---|---|---|
| 15 | **The waitlist has never delivered an email.** Confirmed by the owner. A signup form that silently drops the signup is worse than no form — the visitor believes they are on the list. | Where does a waitlist submission go, and what is the last hop that succeeds? *(Pentest 2026-08-07: live `waitlist` is RLS-on with **0 policies** → an `anon` INSERT is denied at the DB. If the form writes with the publishable key rather than a service-role edge function, every signup fails at the RLS layer — a candidate for the last-hop failure. Confirm the write path.)* |
| 16 | **Cross-account session-reset race** (*pentest 2026-08-07, verified in code; corroborated by CodeRabbit across ~13 controllers*). The gap-#8 fix (`SessionResetRegistry`) clears controller state **synchronously** on sign-out (`auth_provider.dart:31-32`), but account-scoped `async` loads carry **no session-generation guard**: a grep of all `lib/` for any `sessionGeneration/_gen/_epoch` idiom returns nothing. `chat_provider.dart:118-138` (`loadMessages`) does `await Future.delayed(300ms)` → `await getMessages` → unconditional `_messages = ...; notifyListeners()`. On a shared device: A opens a chat (load in flight) → A signs out (`resetForSignOut` clears `_messages`) → B signs in → A's future resolves and writes A's private chat/roster into B's session. The artificial delay *widens* the window. Client-only fix (may be a PR, human-reviewed given child-safety): monotonic generation captured pre-load, re-checked after every `await` before any state write. | Which controllers write state after an `await` without re-checking the session generation, and where should the shared guard live so a new controller can't reintroduce it? |
