# SUPABASE-OWNERSHIP.md

**One production database. Three repositories that can deploy to it.**
This file says which repo is allowed to, and what is still undecided.

Identical copies of this file live in all three repos. If you change one,
change all three:

- `~/the-sporve-web` (and its working clone `~/sporve-launch`) — the web product
- `~/SportsMan-main` — the Flutter production client, **APP**
- `~/Downloads/sporve-landing` — the marketing site + compiled Flutter web, **LANDING**

Production project ref: **`tseszaprvtvqrkfpditu`**.

---

## 1. Why this file exists — the mechanism

The Supabase CLI has no global "which project am I working on" setting. It
resolves its deploy target **from the directory you are standing in**. When you
run a command, it walks up from the current working directory looking for a
`supabase/` folder, then reads `supabase/.temp/project-ref` — a plain text file
containing the project id — to decide which remote it talks to. That file is
written by `supabase link` and is the entire binding. There is no confirmation
prompt naming the project, and nothing in the command output distinguishes
"the project I meant" from "the project this folder happens to point at".

So `supabase db push` typed in the wrong terminal tab is a different command
than the same text typed in the right one. That is the whole hazard.

The second half of the hazard is the **ledger**. Supabase tracks applied
migrations in one server-side table, `supabase_migrations.schema_migrations`.
It holds a row per migration version string that has been applied. `db push`
does exactly one thing: it compares your local `supabase/migrations/*.sql`
filenames against that table and runs every file whose version is **not** in the
table. It does not inspect the schema. It does not diff anything. A migration
that was applied by hand in the SQL editor leaves no row, so the CLI believes it
never ran and will run it again.

There is **one** ledger for the project, shared by every repo that links to it.
Two repos with different migration folders pointed at one ledger is not two
opinions about the schema — it is one ledger being fought over by two histories.

### What production's ledger actually says (2026-08-11)

| fact | value |
|---|---|
| entries in `supabase_migrations.schema_migrations` | **17**, last `20260725033343` |
| migration files in **APP** (`SportsMan-main`) | 73 |
| migration files in **LANDING** (`sporve-landing`) | 8 |
| entries that came from APP | **0** |

Most of the production schema was applied **by hand in the SQL editor**. The
objects exist; the rows recording them do not. This means **neither repo's
migration folder describes production**, and the delta between any repo and prod
cannot be computed by any tool — only by dumping prod and reading it.

Concretely: running `supabase db push` from APP today would attempt all 73
migrations, because the ledger claims none have run. Many create objects that
already exist. Best case it aborts on the first collision. Worst case it applies
half of them, and prod ends up in a state no file anywhere describes.

**Until the recovery work in Phase 0.2 of `docs/launch/00-backlog.md` is done
(dump prod, write a `00000000000000_prod_baseline.sql`, mark it applied), the
correct number of `db push` commands to run against production is zero.**

---

## 2. Ownership

| surface | owner | status |
|---|---|---|
| `supabase/functions/` (edge functions) | **LANDING** (`~/Downloads/sporve-landing`) | decided, on evidence |
| `supabase/migrations/` (schema) | **UNRESOLVED** | see §4 — owner must decide |
| Supabase secrets / env vars | owner, by hand in the dashboard | never in a repo |
| `supabase/config.toml` | each repo keeps its own; it is local config, not a deploy target | — |

### 2.1 Edge functions — LANDING owns them

Evidence, gathered 2026-08-11:

1. **LANDING's copy is the newer one in every function that exists in both.**
   Ten functions are present in both repos and differ. LANDING's file is larger
   in all ten. Byte counts of `index.ts`:

   | function | LANDING | APP |
   |---|---|---|
   | `ai-gateway` | 43,511 | 14,635 |
   | `chat-answer` | 18,002 | 6,366 |
   | `generate-embedding` | 15,871 | 5,204 |
   | `ai-chat` | 12,741 | 5,086 |
   | `ai-match` | 12,240 | 9,517 |
   | `search-parse` | 9,244 | 8,829 |
   | `search-execute` | 7,947 | 6,869 |

   Size alone is weak evidence. Size in the same direction across ten
   independent files is not — it is a fork that was developed on one side only.

2. **Production's migration ledger contains exactly LANDING's AI-observability
   tables.** The tables that `ai-gateway` writes to were created by LANDING's
   migrations (`20260715000001_ai_observability.sql` and siblings), and those
   version strings are in the ledger. The deployed functions and LANDING's
   schema are the same lineage.

3. **LANDING carries the operational apparatus for these functions** —
   `supabase/AI-DEPLOYMENT.md`, `supabase/AI-OBSERVABILITY-RUNBOOK.md`, and
   `scripts/ai-release-safety.mjs`, `scripts/probe-ai-ingress.mjs`,
   `scripts/run-ai-evals.mjs`, `scripts/run-ai-smoke.mjs`. APP has no `scripts/`
   directory at all.

**Therefore: `supabase functions deploy` runs from LANDING only.**

APP's `supabase/functions/` (33 directories) is now **reference material, not a
deploy source**. It is not deleted — it still contains functions LANDING does
not have, including the Stripe path — but nothing in it may be deployed until
that function has been reconciled into LANDING or the decision in §4 moves it.

> Open sub-question, not settled by the above: APP holds Stripe functions that
> LANDING does not. Deploying a *money* function from a repo that does not own
> the function set is exactly the class of accident this file exists to prevent.
> Resolve it as part of §4 rather than by exception.

---

## 3. The hard rules

1. **Only the owning repo runs the deploy command for its surface.**
   - `supabase functions deploy …` → **LANDING only**.
   - `supabase db push` → **nobody, today.** After §4 is decided and the
     baseline exists, the repo named there, and only that one.
2. **`supabase link` in a non-owning repo is itself the violation.** The damage
   is done at link time; the destructive command is just the trigger. If a repo
   should not deploy, it should not be linked.
3. **`supabase/.temp/` is never committed, and never exists in more than one
   repo at a time.** It is machine-local state, it names the production project,
   and a second copy is a second loaded gun. Both APP and LANDING already ignore
   it (`SportsMan-main/.gitignore:60`, `sporve-landing/.gitignore:9`), and
   neither has ever tracked it — verified 2026-08-11 with `git ls-files`.
   As of 2026-08-11: **APP is linked** (`supabase/.temp/project-ref` =
   `tseszaprvtvqrkfpditu`); **LANDING is unlinked** (its `.temp` was renamed to
   `.temp.unlinked-2026-08-11`).

   Two live gaps in that, found while writing this file:
   - The ignore rule is `supabase/.temp/` with a trailing slash, so the renamed
     `supabase/.temp.unlinked-2026-08-11/` in LANDING is **not** ignored and
     currently shows as untracked. Broadening the rule to `supabase/.temp*`
     closes it. The pre-push hook already blocks both spellings.
   - APP committed `supabase/.temp/` once, in `35794f1` (2026-07-07), and
     untracked it in `96565c1` (2026-08-02). The project ref and organization id
     are therefore still in that repo's git history. Neither is a credential —
     the credential exposure is the service-role key, tracked as `[RED]` in
     `docs/launch/00-backlog.md` §0.1 — but it is why rule 3 is a rule.
4. **Prod is never the first place a schema change runs.** Once Docker is
   installed, `supabase db reset` locally, then push.
5. **Secrets live in the Supabase dashboard**, not in a repo, not in `.env` that
   sits next to a linked `supabase/` folder.

### The rule and the reality do not currently agree

Rule 1 says functions deploy from LANDING. Rule 3 records that LANDING is the
repo that is **unlinked**, and APP is the one that is linked. That is
deliberate, and it is the safe ordering: the *linked* repo is the one whose 73
unrecorded migrations could destroy prod, so unlinking removed the wrong kind of
risk first. Before the next function deploy, LANDING must be relinked (§5) and
APP must be unlinked. Do not leave both linked.

---

## 4. Migration ownership — UNRESOLVED

This is a decision the owner has to make. It is recorded here unmade rather than
guessed, because guessing it wrong costs the production database.

Neither option is available until prod is dumped to a baseline (backlog 0.2).
Both options begin the same way: dump production, commit it as
`00000000000000_prod_baseline.sql`, and insert its version into the ledger so
the CLI stops believing 73 migrations are outstanding.

### Option A — APP (`SportsMan-main`) owns migrations

**For.** It holds 73 migrations, the largest authored history, and the schema
the Flutter client's code actually expects. The outcome-model work — the newer
schema production is *behind* — lives here. Choosing anything else means that
history is orphaned or hand-merged.

**Against.** Zero of its 73 migrations are in the production ledger. Its
relationship to prod is not "ahead by N" — it is **unknown**, and stays unknown
until every one of the 73 is classified as already-applied, partly-applied, or
never-applied. Production has ~36 tables where this set describes ~65. This is
the biggest reconciliation job of the two, and the one most likely to be
abandoned half-done, which would leave the exact ambiguity we are trying to end.

**Cost.** High up front. Correct at the end.

### Option B — LANDING (`sporve-landing`) owns migrations

**For.** Its 8 migrations *are* in the production ledger, so its lineage and
prod's already agree. It also owns edge functions, so one repo would own the
whole server side — one place to look, one place to link, one CI target. The
ambiguity this file exists to end would actually end.

**Against.** It inherits 73 migrations it did not write and whose intent it does
not carry, and the Flutter client's schema expectations then live in a repo that
knows nothing about the Flutter client. The web/marketing repo becomes the
database owner, which is organisationally odd and will read as wrong to anyone
who joins later.

**Cost.** Low up front. A naming/ownership mismatch to live with.

### The trade-off in one line

**A** aligns ownership with intent and pays for it in reconciliation work.
**B** aligns ownership with the ledger and pays for it in the schema living in
the wrong-shaped repo.

### The question that settles it

> When the outcome-model schema ships, whose migration files will be written —
> the Flutter engineer's, or the web/backend one's?

Whoever writes the *next* migration should own the folder. Ownership by
authorship survives; ownership by convenience gets violated within a month.

Until this is answered, **`supabase db push` is forbidden from both repos.**

---

## 5. Recovery — relinking

If a repo needs to be (re)linked — and it is the owning repo for the surface you
are about to deploy:

```bash
cd <the owning repo>
supabase link --project-ref tseszaprvtvqrkfpditu
```

This writes `supabase/.temp/` with the project ref, pooler URL and server
versions. It will ask for the database password; that is the Postgres password
from the dashboard, not your Supabase account password.

To unlink, just remove the state — there is no `supabase unlink`:

```bash
mv supabase/.temp supabase/.temp.unlinked-$(date +%Y-%m-%d)
```

Renaming rather than deleting keeps the evidence of what was linked and when.

To confirm what a folder is currently pointed at, without running anything that
touches the server:

```bash
cat supabase/.temp/project-ref 2>/dev/null || echo "not linked"
```

---

## 6. What the guards in this repo do

Both APP and LANDING carry two files. Read `scripts/supabase-guard.sh` before
trusting it — its own comments state its limits.

- **`.git/hooks/pre-push`** — fires on `git push` only. It warns when the repo
  is linked (`supabase/.temp/` present) but is not the designated owner, and
  fails the push if `supabase/.temp/` was ever staged. It **cannot** intercept
  `supabase db push` or `supabase functions deploy`; those are not git
  operations and git never sees them.
- **`scripts/supabase-guard.sh`** — a shell function you must *opt into* by
  sourcing it in your shell profile. Once sourced, it shadows the `supabase`
  command and refuses `db push` / `functions deploy` from a non-owning repo. If
  you have not sourced it, or you invoke `/opt/homebrew/bin/supabase` by full
  path, it does nothing.

Neither is a security control. Both are seatbelts against your own muscle
memory, which is the actual failure mode here.

---

## 7. Changelog

- **2026-08-11 — created.** Decided: LANDING owns edge functions, on the
  evidence in §2.1 (LANDING's copy larger in all ten shared functions;
  production's ledger contains exactly LANDING's AI-observability migrations;
  LANDING holds the deployment runbooks and release-safety scripts). Recorded as
  unresolved: migration ownership (§4). Recorded as fact from a direct
  production query the same day: 17 ledger entries ending `20260725033343`, none
  from APP; 36 tables; 97 RLS policies. LANDING unlinked from prod
  (`supabase/.temp` → `.temp.unlinked-2026-08-11`); APP still linked. Guards
  added to both repos. Author: Clo, reviewed by the owner.
