# Sporv — Product Development Spec Set v2
Written against a fresh clone of `srikanthvishnu90-sketch/sporve-agent-clone`, 50 migrations, verified 2026-09-15.

| # | Document | Gate | State |
|---|---|---|---|
| 00 | [MASTER](00-MASTER.md) | — | Ladder, cut rule, conventions, what changed in v2 |
| 11 | WEB-SURFACE *(not yet filed)* | G8, G9 | Partial — no service worker, no offline queue, no role shell |
| 12 | SCHEDULING-ATTENDANCE *(not yet filed)* | **G7** | **Green-field. Highest value in the set.** |
| 13 | PARENT-ZERO-INSTALL *(not yet filed)* | **G8** | Green-field. Zero `magic_link` or `twilio` matches. |
| 14 | REGISTRATION-PROGRAMS *(not yet filed)* | G8–G10 | Green-field. Zero `registration` or `discount` matches. |
| 15 | AGENT-AUTOMATION *(not yet filed)* | G6 | Spine exists. Job catalog and evals missing. |
| 16 | [COMPLIANCE-MINORS](16-COMPLIANCE-MINORS.md) | G2, G4 | Partial. **Badge integrity is the top open risk.** |
| 17 | MIGRATION-ONBOARDING *(not yet filed)* | **G10** | Green-field. This is the distribution gate. |
| 18 | RELIABILITY-COMMERCIAL *(not yet filed)* | — | Blocks the first paid contract |

v1 specs 01 (object graph), 03 (capacity/resources), 04 (money live), 05 (identity/consent), 07 (agent write safety), 08 (connectors) stand unchanged and are still in force. 02, 06, 09, 10 are superseded by 12, 13, 17, and 14 respectively.

## Start here, in this order
1. **12 — Scheduling.** The product is called a management system and has no schedule. Nothing downstream works without it.
2. **13 — Parent zero-install**, in parallel. Start A2P 10DLC registration on day one; the review queue is measured in weeks and it gates every SMS.
3. **16 — The badge.** Independent of everything, fixable this week, and the single largest liability in the repo.
4. **17 — Migration.** The Sports Connect 2027 sunset is the largest pool of forced-migration buyers in this market. The importer is the sales demo.

## The honest read on timing
The buying window is November through January, before winter and spring registration opens. Scheduling, the parent channel, and registration are all green-field. Money does not yet reconcile live. That is not eight weeks of work at any realistic velocity.
Something gets cut. Cut it deliberately, using the rule in `00-MASTER.md §0.1`, rather than letting the calendar cut it for you. The most defensible narrow launch is: schedule + attendance + zero-install parent channel + dues collection, with registration deferred to the following cycle and migration handled manually by you for the first ten orgs.
Ten orgs running a full season beats a hundred orgs signed and none live.

> Filed 2026-09-15 from the owner's pasted set. Only 00, this index, and 16 were provided; 11–15, 17, 18 are referenced but not yet pasted.

---

## Rulings — 2026-09-15 (see `../decisions/2026-09-15-rulings.md`)
- **R1** `providers` stays the org root; new tables carry `provider_id`. The rename is recorded debt, paid after G9.
- **R2** `GATES.md` is canonical and now holds the v2 **G1-G10** ladder. **G3 SUPPLY is deleted** (it graded a two-sided marketplace we no longer operate; G9 is the harder successor).
- **R3** Flutter retirement deletes the **client only**; `supabase/` stays. Duplicate edge functions across the two repos are a separate, unscheduled task.
- **R4** The narrow launch **cuts migration (17)** and **keeps registration (14)** — the reverse of the proposal above. G10 is explicitly not a launch gate; the first ten migrations are done by hand and they specify the importer.
- **R5** Cancellation **always drafts**. 12.4's <15s is approval-to-delivery; optimise for two taps from the home screen with a pre-written draft.

