# 0.4 — Environment record

Backlog item 0.4. Recorded **2026-08-11** on the owner's machine, by running the
version commands directly. Every number below is measured, not assumed.

This exists so that when a production baseline dump is finally taken, the file
can say which tools produced it. A `pg_dump` from one CLI version and a restore
from another is a real source of silent difference — output format, quoting of
identifiers, and whether extensions and policies are included have all changed
between Supabase CLI minors.

**No `supabase` subcommand was executed to produce this record.** `--version`
reads the local binary and touches no project.

---

## Host

| | |
|---|---|
| machine | Apple Silicon (`arm64`) |
| OS | macOS 14.5 (build 23F79) |
| shell | zsh |
| package manager | Homebrew 6.0.15 |

## Toolchain — present

| tool | version | path / source | notes |
|---|---|---|---|
| Supabase CLI | **2.109.0** | `/opt/homebrew/bin/supabase` (brew) | latest published is **2.113.0** — four patch/minor releases behind |
| git | **2.39.5** (Apple Git-154) | Xcode CLT | ships with macOS; fine for hooks |
| python3 | **3.9.6** | `/usr/bin/python3` (system) | this is what runs `src/build.py` |
| node | **v24.16.0** | nvm (`~/.nvm/versions/node/v24.16.0/bin/node`) | |
| npm | **11.13.0** | with node above | |
| gh | **2.92.0** (2026-04-28) | brew | authenticated as `srikanthvishnu90-sketch`, HTTPS, keyring token |
| flutter | **3.44.2** stable | | for `SportsMan-main` |
| dart | **3.12.2** (stable, 2026-06-09) | with flutter | `dart analyze` available |

## Toolchain — missing, and what each one blocks

| tool | state | what it blocks |
|---|---|---|
| **Docker** | not installed — no `docker` binary, no daemon | `supabase start`, `supabase db reset`, `supabase db diff`, `supabase db pull`, `supabase functions serve`, and — expected but unverified — `supabase db dump`, since the CLI runs Postgres tooling inside a container image. Also blocks the deep `strix-agent` pentest pass. |
| **Vercel CLI** | not installed — no `vercel` binary | `vercel env pull`, `vercel logs`, `vercel inspect`. Does **not** block deploys: `the-sporve-web` deploys from a `main` push through the git integration, so shipping still works. It blocks *diagnosing* a failed deploy and reading the production env var set. |
| **Deno** | not installed | local typecheck of edge functions (`deno check supabase/functions/*/index.ts`). Today a function's first type-check is on the Supabase build server, during a deploy to production. |

### Why Docker is the one that matters

Without Docker there is no local Postgres, so there is no way to run a migration
anywhere except production. Every `db push` is therefore a first execution
against live data, with no rehearsal and no rollback. Combined with the state
recorded in `SUPABASE-OWNERSHIP.md` — production's migration ledger holds 17
entries and none of `SportsMan-main`'s 73 files are among them — this is why
`db push` is currently forbidden from every repo rather than merely restricted
to one.

Installing Docker does not fix the ledger. It makes fixing the ledger
survivable.

## Install commands, exact

```bash
brew install --cask docker      # then open /Applications/Docker.app once and let it start
npm i -g vercel                 # 'vercel login' after, then 'vercel link' in the web repo
brew install deno               # optional, for local edge-function typecheck
brew upgrade supabase           # 2.109.0 -> 2.113.0
```

Take the CLI upgrade **before** the baseline dump, not after, so there is one
version on both sides of the recovery. Then re-record the number below.

## Version the baseline was produced with

Fill this in when backlog 0.2's `supabase db dump` actually runs. Leave it blank
rather than guessing.

| artifact | tool + version | date |
|---|---|---|
| `00000000000000_prod_baseline.sql` | _not yet taken_ | — |
| `prod-policies-2026-08-11.sql` | _not yet taken_ | — |

## Reproducing this record

```bash
supabase --version; git --version; python3 --version; node --version
npm --version; gh --version | head -1
command -v docker || echo "docker: absent"
command -v vercel || echo "vercel: absent"
command -v deno   || echo "deno: absent"
```

## Related state checked the same day

- Neither `SportsMan-main` nor `sporve-landing` sets `core.hooksPath`, so the
  per-repo `.git/hooks/pre-push` installed under backlog 0.1 will actually fire.
  If either repo ever sets that config, the hooks are bypassed silently.
- Both repos ignore `supabase/.temp/` (`SportsMan-main/.gitignore:60`,
  `sporve-landing/.gitignore:9`) and neither tracks it in `HEAD`.
- `SportsMan-main` **did** commit `supabase/.temp/` historically in `35794f1`
  (2026-07-07) and untracked it in `96565c1` (2026-08-02). The project ref and
  organization id remain in that repo's git history. Neither is a credential;
  the credential exposure is tracked separately as a `[RED]` item in
  `docs/launch/00-backlog.md` §0.1.
