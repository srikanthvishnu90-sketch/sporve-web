# 0.3 — Version-control hygiene across APP and LANDING

Read-only investigation. No `supabase` command run, no database contacted, no
push. Method: `rg -l` to locate, `git log`/`diff`/`shasum` to compare, line
ranges read.

- **APP** = `/Users/vishnusrikanth/SportsMan-main`
- **LANDING** = `/Users/vishnusrikanth/Downloads/sporve-landing`

---

## 0. Headline — the ownership conclusion is WRONG as stated

> "LANDING owns the AI/search edge functions and APP's copies are stale."

**Half of that is right and half is backwards, and the wrong half is the
dangerous half.**

| Claim | Verdict |
|---|---|
| LANDING is the *declared* owner of the 11 AI functions | **HOLDS** — `LANDING/supabase/config.toml:4-35` declares `[functions.*]` for all 11; `APP/supabase/config.toml:33-39` declares only `stripe-webhook` and `lifecycle-process`. |
| LANDING actually *deploys* them | **CONTRADICTED** — the only recorded deploy of these functions to prod came from **APP**. |
| APP's copies are "stale" | **FALSE** — APP's copies are **17 days newer** by commit date. |
| Larger file = canonical | **FALSE PREMISE** — line count measures generation, not recency. |

### The decisive evidence

**(a) APP holds the only deploy receipt in either repo's history.**
`APP` commit `808a793` (2026-07-27) carries, verbatim in its commit body, an
MCP deploy response:

```
{"project_ref":"tseszaprvtvqrkfpditu","functions":["ai-chat","ai-gateway",
"ai-match","backfill-embeddings","chat-answer","chat-parse-query",
"enrich-listing","generate-embedding","generate-proposals","goal-formulate",
"lifecycle-approve","lifecycle-process","message-draft","parent-update-send",
"plan-progress","provider-onboard-draft","search-execute","search-parse",
"session-note-summarize","stripe-connect-onboarding","stripe-create-checkout",
"stripe-webhook"],"message":"Deployed Functions."}
```

That list contains **all 12 shared functions**. `git log --all --grep='Deployed
Functions'` and `--grep='project_ref'` in LANDING return **zero** results.

**(b) APP is the only repo still CLI-linked.**
`APP/supabase/.temp/linked-project.json` → `{"ref":"tseszaprvtvqrkfpditu",…}`.
LANDING's is gone — renamed `supabase/.temp.unlinked-2026-08-11`. LANDING
**cannot** deploy today without a re-`link`. So whatever was true historically,
the *operative* deploy path right now is APP.

**(c) Recency runs the other way.**

| | shared fns last touched |
|---|---|
| APP | **2026-08-01** (`87758eb`), except `generate-proposals`/`goal-formulate` 2026-07-27 |
| LANDING | **2026-07-15**, except those same two at 2026-07-27 |

**(d) Neither repo deploys functions from CI.** Checked every workflow:
`APP/.github/workflows/{ci,ledger-sweep,outcome-agent,rls-audit,roadmap-agents,sentinel,stripe-review}.yml`
and `LANDING/.github/workflows/{release-gate,sentinel}.yml`. `ci.yml:18-26` only
runs a *local* `supabase start` / `db reset` / `db lint`. **Deployment of edge
functions is 100% manual, from a laptop, with no record.** That, not "which
repo is bigger", is the actual hygiene defect.

**(e) Docs point both ways.** `LANDING/supabase/AI-DEPLOYMENT.md:42-52` gives
`functions deploy … --project-ref tseszaprvtvqrkfpditu` for 11 AI functions.
`APP/docs/GO-LIVE-RUNBOOK.md:61`, `docs/RECAP-WIRING.md:34`,
`docs/DRAFT-REPLY-WEBHOOK.md:31`, `docs/ai-key-setup.md:23` give deploy
commands for APP-only functions **and for `ai-chat`**, which is shared. Two
runbooks, one project, overlapping scope.

### What this actually is

Not "canonical vs stale". It is a **fork**: two independently-evolved
generations of the same 12 functions, evolved in parallel from a common
2026-07-07 ancestor, with **incompatible database dependencies**.

The sharpest proof — the two gateways call **different rate-limit RPCs**:

| | quota mechanism | RPC defined in |
|---|---|---|
| APP `ai-gateway:86` | `admin.rpc("consume_edge_rate_limit", …)` | `APP/supabase/migrations/20260723_000007_edge_rate_limits.sql:17` **only** |
| LANDING `ai-gateway:760` | `admin.rpc("reserve_ai_capacity", …)` | `LANDING/supabase/migrations/20260715000003_ai_quota_reservation.sql:15` **only** |

Deleting either repo's copies deletes the code path that matches half the
database. **Whichever gateway is live in prod, the other's RPC may not exist.**
This is settleable in one query and is not settleable by reading files — see
§8.

---

## 1. Function inventory

12 shared (excluding `_shared/`), 20 APP-only, 2 LANDING-only.

- **APP-only (20):** `backfill-embeddings`, `camp-broadcast`, `camp-recap`,
  `coach-command`, `coach-invoice-create`, `draft-recap`, `draft-reply`,
  `enrich-listing`, `lifecycle-approve`, `lifecycle-process`, `message-draft`,
  `parent-update-send`, `plan-progress`, `setup-interview`,
  `stripe-connect-onboarding`, `stripe-create-checkout`,
  `stripe-provider-payouts`, `stripe-webhook`, `tests`, `waitlist-offer-draft`
- **LANDING-only (2):** `ai-feedback`, `join-waitlist`

`_shared/` also diverges: APP has `auth.ts`, `coach_voice.ts`, `http.ts`,
`market.ts`, `push.ts`; LANDING has `ai-observability.ts`, `market.ts`.
`_shared/market.ts` **differs** (APP 47 lines, LANDING 180).

---

## 2. The two same-length functions — byte-identical

`shasum -a256` matches exactly:

| function | lines | result |
|---|---|---|
| `generate-proposals` | 298 / 298 | **byte-identical** |
| `goal-formulate` | 147 / 147 | **byte-identical** |

Not coincidence. LANDING commit `c12ba25` (2026-07-27) is literally titled
*"feat(ai): sync goal-formulate + grounded generate-proposals to canonical repo
(L-012)"*, and APP commit `808a793` the same day authored them. They were
copied deliberately.

Note both are **absent from `LANDING/supabase/config.toml`** — the only two
shared functions LANDING does not declare. LANDING holds them as a mirror, not
as an owner.

**Recommendation: DELETE from LANDING.** Zero information loss (byte-identical),
and LANDING does not declare them.

---

## 3. The 10 divergent functions — what each side has

Read from the diffs, not inferred. **The `!` rows are the lossy ones.**

| function | LANDING has that APP lacks | APP has that LANDING lacks |
|---|---|---|
| `ai-gateway` (344→1102) | `recordAiEvent` observability (`_shared/ai-observability.ts`); `envInt/envFloat` clamped env parsing; `reserve_ai_capacity` atomic quota reservation; 6 MB request ceiling for image payloads | **!** `consume_edge_rate_limit` RPC quota; `ALLOWED_TASKS`/`ALLOWED_MODELS` allowlists with the explicit *"never Opus implicitly"* default (`:76`) |
| `ai-chat` (123→301) | **!** Hard child-safety refusal: `HEALTH_REQUEST`/`TRAINING_REQUEST` regex preflight returning a canned "contact a healthcare professional" reply *before* the model is called | Uses `_shared/http.ts` `readBoundedJson`; safety is **system-prompt only** (`:46`, `:50`) — advisory, not enforced |
| `ai-match` (190→311) | **!** Architectural change: `ranking-policy.ts` (`rankEligible`, `groundedWhy`, `objectiveScore`) — *"Production matching no longer calls a model"*; per-actor rate reservation; role loading | **!** Still model-ranked. Plus the only tests: `matchguard.test.mjs`, `gates_test.sh`, `gates_test.sql` |
| `chat-answer` (128→467) | `recordAiEvent` + `GroundingStatus`; canonical program re-fetch (`loadCanonicalPrograms`) so prices/policies are rendered from the DB not the model; UUID validation; intent allowlist | `_shared/http.ts` bounded-body reader |
| `chat-parse-query` (134→205) | `boundedInteger`/`boundedNumber`/`allowedString` coercion on every parsed field; 4 KB body / 1 KB query caps | `_shared/http.ts` bounded-body reader |
| `generate-embedding` (117→430) | Clamped env config, 12 s timeout, per-minute + per-day rate limits, `recordAiEvent` | **!** A **Voyage** provider branch (`embedTextVoyage`) and `EMBEDDING_PROVIDER` switch. LANDING is hardcoded to OpenAI `text-embedding-3-small`. |
| `provider-onboard-draft` (195→398) | Image-upload path: media-type allowlist, 5 MB image cap, base64 length cap, bounded text fields | **!** `guardrail.test.mjs`. Guardrail logic itself: APP 99 lines vs LANDING 106 — differs only in comments + formatting on inspection, but **not byte-identical**, so verify before discarding either. |
| `session-note-summarize` (157→355) | Bounded text/list validation on every input field | **!** `guardrail.test.mjs`. Guardrail 143 vs 161 lines — LANDING reflows the sport-skill list; APP's comment block documents the grounding rule. |
| `search-execute` (137→165) | `resolveMarketLocation` + `canonicalMetro` + `SEARCH_METRO_ALLOWLIST_JSON` — maps "Chicago, IL" to a metro key and **fails clearly** instead of returning global/empty results | **!** `if (req.method !== "POST") return 405` (LANDING has no method allowlist); `explain.test.mjs` |
| `search-parse` (175→183) | Inline `getUser()` auth with an explanatory comment | **!** `405` method allowlist; **generic 500 body**. LANDING returns `(e as Error).message` to the caller (`:181`) — internal error text leaked to clients. |

### The three findings most likely to be missed

1. **`ai-match` is not a diff, it is a rewrite.** LANDING removed the model from
   the production matching path entirely. Deleting LANDING's copy re-introduces
   LLM-decided matching. Deleting APP's copy loses the only test suite for it.
   **[CRITICAL-PATH — this decides which coach a child is matched with.]**
2. **`ai-chat` safety is enforced in LANDING and merely *requested* in APP.** A
   system prompt is a suggestion to a model; a regex preflight is a control.
   Deleting LANDING's `ai-chat` removes the only hard refusal on injury/medical
   questions from a product used by parents of minors. **[CRITICAL-PATH]**
3. **APP has the only tests, in five files, and they die with it:**
   `ai-match/{matchguard.test.mjs,gates_test.sh,gates_test.sql}`,
   `provider-onboard-draft/guardrail.test.mjs`,
   `search-execute/explain.test.mjs`,
   `session-note-summarize/guardrail.test.mjs`.
   `explain.ts` is **byte-identical** across repos, so `explain.test.mjs` is
   directly portable; the other guards differ and the tests would need review.

### Recommendation for the 10

**NEEDS-OWNER-DECISION — do not delete either side yet.** This is not a
stale-copy cleanup; it is a merge. Neither tree is a superset. The correct
sequence is:

1. Read prod's live function source (dashboard → Edge Functions → each function)
   and record which generation is actually running. Until that is known, every
   deletion is a coin flip.
2. Port the four uniquely-valuable APP behaviours forward (`405` method gate,
   generic 500 body, Opus-never-implicit allowlist, Voyage branch or a decision
   to drop it) plus the five test files.
3. Then, and only then, delete the loser — one function at a time, each with the
   live source diffed first.

---

## 4. Duplicate migrations — both byte-identical

`diff` returns silent for both:

| file | APP | LANDING | result |
|---|---|---|---|
| `20260726_000000_booking_member_org_guard.sql` | 3619 B | 3619 B | **byte-identical** |
| `20260710_000000_session_trainer.sql` | 912 B | 912 B | **byte-identical** |

**Recommendation: DELETE BOTH FROM LANDING. Keep in APP.**

Evidence: APP holds 73 migrations to LANDING's 8, including the
`organization_members`, `programs`, `sessions` and `services` tables these two
files depend on. LANDING's copies reference tables LANDING never defines. A
`db push` from LANDING would try to create a trigger on `public.bookings` with
no local definition of it.

**This is the single highest-value deletion in the document** — see §5 for why
the booking guard specifically is dangerous where it currently sits.

---

## 5. `enforce_booking_member_org()` — CONFIRMED, defined three times

| # | location | scope |
|---|---|---|
| v1 | `APP/…/20260726_000000_booking_member_org_guard.sql:23` | program_id → session_id |
| v2 | `LANDING/…/20260726_000000_booking_member_org_guard.sql:23` | **identical to v1** |
| v3 | `APP/…/20260729_000610_org_services.sql:115` | program_id → session_id → **service_id** |

### Are they semantically identical? No — v3 is a deliberate widening.

v3 adds a third org-resolution branch:

```sql
elsif new.service_id is not null then
  select sv.provider_id into v_org from public.services sv where sv.id = new.service_id;
```

and re-binds the trigger with `service_id` added to the watched column list:

```sql
-- v1/v2
before insert or update of assigned_member_id, program_id, session_id on public.bookings
-- v3
before insert or update of assigned_member_id, program_id, session_id, service_id on public.bookings
```

The identity check (`organization_members.id = new.assigned_member_id AND
.organization_id = v_org`), the fail-closed `raise` on unresolvable org, the
`null assigned_member_id → return new` pass-through, `security definer set
search_path = ''`, and the `revoke execute … from public, anon, authenticated`
are all preserved verbatim. v3 is a **strict functional superset**, correctly
ordered (`0729` > `0726`), and its comment explains the split: the
"any-available" rule moved to a dedicated `enforce_service_assignment` guard at
`:152`.

### The real hazard is ordering, not semantics

Because all three are `create or replace`, **the last one applied wins.** v3 is
the newest by filename, so a clean `db push` from APP lands correctly. But:

- **`db push` from LANDING re-applies v2.** LANDING has no `0729` file, so
  `create or replace` reverts the function to the two-branch version and the
  `drop trigger … create trigger` at `:67-69` **narrows the watched column list
  back**, dropping `service_id`. Result: an org-level service booking with a
  non-null `assigned_member_id` and no `program_id`/`session_id` now raises
  `'assigned_member_id set but booking has no resolvable program/org'` — a
  fail-closed break of every service booking with a named trainer. And a
  booking's `service_id` could be re-pointed to another org's service **without
  firing the trigger at all**, leaving a cross-org `assigned_member_id` in
  place. That is the silent one.
- **[CRITICAL-PATH]** This governs whether a child's booking can be attached to
  a trainer outside the booking's organisation.

**Recommendation: DELETE the LANDING copy of
`20260726_000000_booking_member_org_guard.sql`.** Keep both APP files — v1 and
v3 are a legitimate migration sequence, not a duplicate. Do not "clean up" v1;
removing it would break replay from an empty database.

---

## 6. Untracked `.sql` files

`git status --porcelain --untracked-files=all -- '*.sql'`:

- **APP: none.** Clean.
- **LANDING: exactly one**, the already-known
  `supabase/migrations/20260806000000_waitlist_role_allow_athlete.sql` —
  widens the `waitlist.role` CHECK to admit `'athlete'`. Its own header
  documents the defect: `schema.sql` allows only `('parent','coach')` while
  `join-waitlist/index.ts` emits three roles, so an athlete signup violates the
  CHECK, the insert returns `23514`, the function 500s, and the athlete is
  **neither saved nor emailed**. Marked *"AUTHORED, NOT YET APPLIED (human
  applies)."*

**Recommendation: KEEP and COMMIT.** It is the correct fix for a live signup
failure, and it belongs in LANDING because `join-waitlist` and the `waitlist`
table are LANDING-only. Untracked is the worst state for it — invisible to
CodeRabbit, invisible to `git log`, and one `rm -rf` from gone.
Application is a **[CRITICAL-PATH]** owner action.

---

## 7. APP migrations timestamped after `20260725033343`

**42 files.** Listed in filename order; one-line summary from each file's own
header. Most self-declare *"AUTHORED, NOT YET APPLIED."* Applied state is
**not** determined here.

| file | what it does |
|---|---|
| `20260726_000000_booking_member_org_guard.sql` | Booking assigned-member org guard (see §5) **[CRITICAL-PATH]** |
| `20260728_000000_universal_bgcheck_gate.sql` | Universal per-human background-check gate (Roadmap Step 0) **[CRITICAL-PATH]** |
| `20260728_000001_north_star_metrics.sql` | North-star metric instrumentation |
| `20260728_000100_recurring_bookings.sql` | Recurring bookings + packages foundation |
| `20260728_000101_platform_fees.sql` | Platform fee / rake restructure **[CRITICAL-PATH]** |
| `20260728_000200_reviews.sql` | Double-blind reviews + integrity (P1 #5) |
| `20260728_000201_availability_truthfulness.sql` | Availability truthfulness (P1 #6) |
| `20260728_000202_resolution_center.sql` | Resolution centre v1 (P1 #7) |
| `20260728_000203_coppa_gate.sql` | **COPPA consent gate (audit HIGH)** **[CRITICAL-PATH]** |
| `20260728_000300_waitlist.sql` | Coach OS program waitlist (P0 #3) |
| `20260728_000400_coach_invites.sql` | Coach-led family onboarding (P2 #9) |
| `20260728_000401_referrals.sql` | Referral loops foundation (P2 #10) |
| `20260728_000500_recurring_slots.sql` | Recurring weekly availability slots |
| `20260728_000600_coach_policies.sql` | Coach policy fields, data layer only |
| `20260728_000700_ai_drafts.sql` | AI draft storage + feedback corpus |
| `20260728_000701_draft_reply_trigger.sql` | Automatic draft-reply webhook |
| `20260728_000702_resolve_draft_rpc.sql` | Coach accept/reject draft RPC + edit corpus |
| `20260729_000100_services_availability_locations.sql` | Provider model rebuild part 0 — service replaces listing |
| `20260729_000200_group_seats.sql` | Group seats on a service **[CRITICAL-PATH — capacity]** |
| `20260729_000201_recurring_on_service.sql` | Recurring claim on a service |
| `20260729_000202_credit_packs.sql` | Prepaid pack credits **[CRITICAL-PATH — money]** |
| `20260729_000300_coach_invoices.sql` | Off-platform invoicing **[CRITICAL-PATH — money]** |
| `20260729_000500_commission_rates.sql` | Effective-dated org↔trainer commission engine + booking snapshot **[CRITICAL-PATH — money]** |
| `20260729_000510_trainer_affiliation.sql` | Trainer creation, two doors + affiliation state |
| `20260729_000600_venue_resource_layer.sql` | Shared venues + atomic venue-conflict prevention |
| `20260729_000610_org_services.sql` | Org-level staffed services; **third `enforce_booking_member_org`** **[CRITICAL-PATH]** |
| `20260729_000620_shared_inbox.sql` | Shared org inbox routing |
| `20260729_000700_camps.sql` | Camp as a service type |
| `20260729_000701_camp_roster.sql` | Camp ops layer |
| `20260729_000800_waitlist_offers.sql` | Waitlist offer engine |
| `20260729_000900_team_blocks.sql` | Team blocks |
| `20260801_000100_coach_agent_turns.sql` | Coach AI chatbox telemetry + eval corpus |
| `20260801_000200_provider_media_storage.sql` | Provider media storage path **[CRITICAL-PATH — consent]** |
| `20260801_000300_scale_fk_indexes.sql` | Foreign-key index coverage |
| `20260801_000301_scale_query_indexes.sql` | Composite/covering/partial indexes |
| `20260801_000302_scale_rls_initplan.sql` | Wrap bare `auth.uid()` as `(select auth.uid())` — RLS initplan **[CRITICAL-PATH — RLS]** |
| `20260801_000303_scale_append_only_tuning.sql` | BRIN time index + autovacuum tuning |
| `20260802_000101_fix_camp_roster_staff_bgcheck.sql` | Corrective fix #1 — child safety, P1 **[CRITICAL-PATH]** |
| `20260802_000102_fix_booking_update_freeze_service_id.sql` | Corrective fix #2 — gate bypass, P1 **[CRITICAL-PATH]** |
| `20260802_000103_fix_booking_slot_capacity_trigger.sql` | Corrective fix #3 — seat oversell, P0 **[CRITICAL-PATH]** |
| `20260802_000104_fix_refund_stranding_reconciliation.sql` | Corrective fix #4 — refund stranding, P1 **[CRITICAL-PATH — money]** |
| `20260802_000105_fix_p2_hardening.sql` | Corrective fix #5 — three P2 hardening items |

The COPPA gate is indeed among them (`20260728_000203_coppa_gate.sql`), as is
the entire corrective-fix set from the payments audit.

---

## 8. Deletion recommendations, consolidated

| target | call | evidence |
|---|---|---|
| `LANDING/…/20260726_000000_booking_member_org_guard.sql` | **DELETE** | Byte-identical to APP's; LANDING lacks the `0729` superset, so a push from here silently narrows a booking-integrity trigger (§5) |
| `LANDING/…/20260710_000000_session_trainer.sql` | **DELETE** | Byte-identical; depends on tables only APP defines (§4) |
| `LANDING/…/generate-proposals/` | **DELETE** | Byte-identical; not in LANDING's `config.toml` (§2) |
| `LANDING/…/goal-formulate/` | **DELETE** | Byte-identical; not in LANDING's `config.toml` (§2) |
| `LANDING/…/20260806000000_waitlist_role_allow_athlete.sql` | **KEEP — and `git add` it** | Fixes a live athlete-signup 500; LANDING-only surface (§6) |
| The 10 divergent shared functions, **either side** | **NEEDS-OWNER-DECISION** | Neither tree is a superset; incompatible quota RPCs; LANDING holds the only hard child-safety gate, APP holds the only tests and the only method allowlist (§0, §3) |
| APP's 42 post-ledger migrations | **KEEP ALL** | Applied state unknown; several are P0/P1 corrective fixes (§7) |
| `APP/…/20260726_000000_booking_member_org_guard.sql` (v1) | **KEEP** | Removing it breaks replay from empty; v3 is `create or replace` on top of it, not a replacement file (§5) |

### The one question that unblocks the divergent ten

Open `https://supabase.com/dashboard/project/tseszaprvtvqrkfpditu/functions`,
click **ai-gateway**, and read the source. If it calls
`reserve_ai_capacity` → LANDING's generation is live. If it calls
`consume_edge_rate_limit` → APP's is. One string, thirty seconds, and every
row in §3 resolves. **Do that before deleting any edge function.**

---

## What could NOT be verified

- **Which generation of any function is actually running in prod.** No
  `supabase` command was run and no database was contacted, per the brief. All
  ownership evidence here is circumstantial (receipts, link state, config
  declarations, commit dates) — it establishes *who deployed last as recorded*,
  not *what bytes are live*.
- **Whether `consume_edge_rate_limit` and/or `reserve_ai_capacity` exist in
  prod.** Each is defined in exactly one repo's migrations; neither repo's
  lineage is in the 17-entry prod ledger.
- **Whether any of the 42 post-ledger migrations are applied.** The brief
  scoped this out. Their headers claim "NOT YET APPLIED" but 0.2 established
  that objects from unrecorded migrations *do* exist in prod, so the headers
  are not evidence.
- **Whether the deploy receipt in `808a793` reflects a completed deploy or a
  pasted instruction.** The surrounding sentence reads *"Both need {receipt} to
  take effect"* — grammatically mangled, a receipt interpolated into a
  to-do. It is still the strongest deploy evidence in either repo, but it is
  one commit body, not a log.
- **Line-level equivalence of the two `guardrail.ts` pairs.** They differ by 7
  and 18 lines respectively; inspection suggests comments and reflow only, but
  that was not proven token-by-token.
- **Whether LANDING was re-linked after `2026-08-11`.** Only the renamed
  `.temp.unlinked-2026-08-11` directory was observed.

---

## Five-sentence technical reading

**What changed:** nothing — this is a read-only audit that replaces the
working conclusion "LANDING owns the AI edge functions, APP's are stale" with
the evidenced one, "the two repos hold a *fork* of twelve functions, APP's side
is newer and is the only side with a deploy receipt and a live CLI link."
**The mechanism:** the Supabase CLI resolves both migrations and functions from
the current working directory's `supabase/` folder and pushes them at a single
project ref, so two directories aimed at one project produce a split-brain
lineage in which the last writer silently wins; `create or replace function`
makes this lossy rather than conflicting, because reapplying an older
definition succeeds instead of erroring.
**What it touches downstream:** the `ai-gateway` quota path (APP calls
`consume_edge_rate_limit`, LANDING calls `reserve_ai_capacity` — two different
RPCs defined in two different repos, so a wrong deploy calls a function that
may not exist), the `ai-chat` injury/medical refusal that exists only in
LANDING, the model-free `ai-match` ranking policy that exists only in LANDING,
and `enforce_booking_member_org`, a `security definer` trigger — a function that
runs with the *definer's* privileges rather than the caller's, and here fires
`before insert or update` on `bookings` to reject a trainer who is not a roster
member of the booking's organisation.
**What would break it:** `supabase db push` or `supabase functions deploy`
executed from `~/Downloads/sporve-landing` after a re-`link` — the migration
push reverts that trigger from its three-branch form to its two-branch form and
drops `service_id` from the watched column list, so cross-org trainer
assignments on service bookings stop being checked at all, with no error raised
anywhere.
**How it was verified:** `shasum -a256` on all 12 shared function entrypoints
and both duplicate migrations (2 functions and 2 migrations byte-identical, 10
functions differing), `diff` read line-by-line on the ten, `git log --grep` for
deploy receipts across both repos' full history, `git log -1` per file for
recency, direct reads of both `config.toml` files and every `.github/workflows`
YAML, and `git status --porcelain --untracked-files=all` in both trees — with
no `supabase` command run and no database contacted.
