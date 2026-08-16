# 0.1 — Secrets sweep

Read-only audit, 2026-08-11. Three repos:

| Repo | Path | Remote | Visibility assumption |
|---|---|---|---|
| the-sporve-web | `/Users/vishnusrikanth/the-sporve-web` | `github.com/srikanthvishnu90-sketch/sporve-web` (+ `cofounder` remote `charlierich1020/sprove-web-version`) | public |
| sporve-landing | `/Users/vishnusrikanth/Downloads/sporve-landing` | `github.com/srikanthvishnu90-sketch/sporve-landing` | public |
| SportsMan-main | `/Users/vishnusrikanth/SportsMan-main` | `github.com/srikanthvishnu90-sketch/sporve-app` | private (assumed) |

Method: `rg -l` / `rg -n` with `--hidden --no-ignore` (so gitignored files were
also scanned), then targeted line reads. `git log --all -S` (literal pickaxe)
and `-G` (regex pickaxe) for history. No `supabase` command was run, no database
was contacted, nothing was edited, deleted or rotated.

**Headline: no live credential was found on disk, and no credential of any kind
was ever committed to any of the three repositories.** Every pickaxe hit
resolves to a placeholder, a regex inside a secret-scanner, prose in a doc, or a
Skia symbol name. Detail below.

---

## (a) Live findings on disk — severity ranked

| # | Sev | File:line | Type | Gitignored? | Committed? | Assessment |
|---|---|---|---|---|---|---|
| 1 | **LOW** | `/Users/vishnusrikanth/the-sporve-web/.env.local:2` | Vercel OIDC token (RS256 JWT), `eyJhbGci…` (1322 chars) | Yes — `.gitignore:8 .env*` | Never | **Expired 2026-08-05T04:19:04Z.** Not a Supabase key. `sub=owner:srikanthvishnu90-sketchs-projects:project:the-sporve-web:environment:development`, no `role` claim. Vercel CLI writes this; it is 12-hour-lived. |
| 2 | **LOW** | `/Users/vishnusrikanth/Downloads/sporve-landing/.env.local:2` | Vercel OIDC token (RS256 JWT), `eyJhbGci…` (1292 chars) | Yes — `.gitignore:6 .env*` | Never | **Expired 2026-07-09T08:09:05Z.** `sub=…project:sporve:environment:development`, no `role` claim. Same rationale. |
| 3 | INFO | `/Users/vishnusrikanth/SportsMan-main/env.json:3` | Supabase **publishable** key, `sb_publi…` (46 chars) | Yes — `.gitignore:38 env.json` | Never | **Not a finding.** New-format publishable key, the successor to the anon JWT. Public by design; RLS is the control. `lib/core/config/env.dart:4-6` states this constraint in-file. |
| 4 | INFO | `/Users/vishnusrikanth/SportsMan-main/sporve-react/.env.local:5` | Supabase **publishable** key, `sb_publi…` (46 chars) | Yes — `sporve-react/.gitignore:4 *.local` | Never | Same key as #3, mirrored for the Vite prototype. Not a finding. |
| 5 | INFO | `/Users/vishnusrikanth/SportsMan-main/env.json:4` | hCaptcha **site** key, `a8e27646…` (36 chars) | Yes | Never | Site key is the browser-side half. The `HCAPTCHA_SECRET` half appears nowhere on disk in any repo. |
| 6 | INFO | `/Users/vishnusrikanth/SportsMan-main/supabase/functions/.env` | Edge-function secrets file — **all values empty** (`ANTHROPIC_API_KEY=`, `OPENAI_API_KEY=`, only `EMBEDDING_PROVIDER=openai` set) | Yes — `.gitignore:42` | Never | The file that *would* hold the Anthropic key is present and blank. Nothing to leak. |
| 7 | INFO | `/Users/vishnusrikanth/SportsMan-main/supabase/functions/.env.example:7,22,27,28` | Literal placeholders `sk-ant-xxxx…`, `sk-xxxx…`, `sk_test_xxxx…`, `whsec_xxxx…` | No (tracked, intentionally) | Yes, by design | Placeholders. Correct practice. |
| 8 | INFO | `/Users/vishnusrikanth/SportsMan-main/supabase/.temp/pooler-url` | `postgresql://postgres.tseszaprvtvqrkfpditu@aws-1-us-east-2.pooler…` (92 chars) | Yes — `.gitignore:60 supabase/.temp/` | Never | **No password in the URI** — user segment only. Leaks the project ref, which is already public in the client. |
| 9 | INFO | `/Users/vishnusrikanth/the-sporve-web/api/ai.js:169,191` | Anthropic key read from `process.env.ANTHROPIC_API_KEY` | Tracked, public repo | Yes | Correct: the key is referenced, never embedded. This serverless proxy exists precisely so the browser never holds it. |

### Checks that came back clean — stated plainly

- **No `sk-ant-` Anthropic key** with real key material exists on disk in any of the three repos. The only matches are `xxxx` placeholders and prose.
- **No `sk-…`(20+), `sk_live_`, `sk_test_`, `pk_live_`, `rk_live_`, `whsec_`, `sb_secret_`** value exists on disk anywhere. The only `sb_secret_` strings are deliberate negative-test fixtures: `sporve-landing/tests/ai-release-tooling.test.mjs:77` (`'sb_secret_never_send'`) and `tests/ai-eval-harness.test.mjs:133` (`'sb_secret_synthetic_never_send_this'`).
- **No Supabase `service_role` key exists on disk.** Every one of the ~90 files matching the string `service_role` uses it as (i) a Vault secret *name*, (ii) a `Deno.env.get()` lookup, (iii) a Postgres role name in an RLS policy, or (iv) documentation. Representative and correct pattern, `SportsMan-main/supabase/migrations/20260701_000000_lifecycle_process_cron.sql:39`:
  `select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key';`
  The same Vault indirection is used at `20260722_000003_outcome_progress_cron.sql:26`, `20260728_000701_draft_reply_trigger.sql:70`, `20260729_000800_waitlist_offers.sql:355`. **No migration hardcodes a bearer token.**
- **No `service_role` reference in client-reachable Dart.** The single hit under `SportsMan-main/lib/` is a warning comment, `lib/core/config/env.dart:4-6`: *"These are PUBLIC, client-safe values only… service_role, the hCaptcha secret, Stripe secret, Resend key — must NEVER be…"*.
- **No legacy Supabase JWT (`eyJ…` anon or service_role) anywhere in any repo, on disk or in history.** Both projects have migrated to the `sb_publishable_` key format, which removes the whole anon-vs-service-role JWT confusion class.
- **`the-sporve-web/index.html:36` contains `eyJ…` substrings — these are not JWTs.** They are byte runs inside the base64 inlined fonts (they contain `+` and `/` and have no `.`-delimited three-part structure). Verified with a strict `eyJ…\.…\.…` regex, which matches nothing in that file. Do not re-flag this next sweep.
- **No `.pem`, `.p12`, credential or keyfile is tracked** in any of the three repos.
- **No `node_modules` is tracked** in SportsMan-main (`git ls-files | grep -c node_modules` → 0), so the vendored `web_next_port_DELETED_OK` tree adds no secret surface. Its one `eyJ…` hit (`package-lock.json:4954`) is an npm `sha512-` integrity hash.

---

## (b) Git-history findings

Pickaxed every repo across **all refs** for `sk-ant-`, `sk_live_`, `sk_test_`,
`whsec_`, `sb_secret_`, `SUPABASE_SERVICE_ROLE_KEY`, `service_role_key`, and
(by regex) any three-part JWT `eyJ…​.…​.…`.

**Result: zero real credentials in history, in any repo.**

- `the-sporve-web` — **no hit on any pattern.** Clean history, including the JWT regex. No `.env*` file has ever been added (`git log --all --diff-filter=A --name-only -- '.env*' …` → empty).
- `sporve-landing` — hits, all benign after inspection:

| Commit | Date | File | What actually matched |
|---|---|---|---|
| `c39d643`, `07b2ace` | 2026-07-08 | `SECURITY_AUDIT.md` | The prefix strings `sk-ant-` / `sk_live_` written as prose in the audit. A strict "prefix + 6 or more key chars" regex matches **nothing** in that file. |
| `c39d643`, `07b2ace` | 2026-07-08 | `app/canvaskit/skwasm.js.symbols`, `skwasm_heavy.js.symbols`, `wimp.js.symbols` | Skia symbol names such as `sk_test_bit`. Not Stripe. |
| `62d8517` | 2026-07-26 | `.claude/hooks/secret_scan.py` | The scanner's own detection regexes, e.g. line 25 `(r"sk_live_[A-Za-z0-9]{20,}", "Stripe live secret key")`. |
| `cb29579` | 2026-07-27 | `.claude/prompts/sentinel.md`, `.claude/agents/sentinel.md` | Prefix list in the sentinel agent's instructions. |
| `72dc415`, `6b47de9`, `c12ba25` | 2026-07-15 / 07-27 | 12 files under `supabase/functions/**`, `scripts/**` | The *env var name* `SUPABASE_SERVICE_ROLE_KEY` inside `Deno.env.get(...)` calls. Never a value. |

- `SportsMan-main` — hits, all benign:

| Commit | Date | File | What actually matched |
|---|---|---|---|
| `35794f1` | 2026-07-07 | `docs/ai-key-setup.md`, `supabase/functions/.env.example` | Setup instructions and `xxxx` placeholders. Strict regex against the blob at that commit → no match. |
| `90b697b` | 2026-08-05 | `SYSTEM-MAP.md` | Prose describing the key format. |
| `87758eb` | 2026-08-01 | `supabase/functions/.env.example` | Placeholders `sk_test_xxxx`, `whsec_xxxx`. |
| `4279391` | 2026-08-02 | `supabase/functions/tests/stripe-webhook.test.ts` | Synthetic webhook-signature test fixtures. |
| `98a0369` | 2026-07-27 | `.claude/agents/sentinel.md` | Detection prefix list. |
| `87758eb`, `2045f0e`, `a647d32`, `f2a7d0f`, `1d9dd3f`, `808a793`, `35794f1` | Jul–Aug 2026 | migrations + edge functions | Vault secret **name** `service_role_key` and env-var **name** `SUPABASE_SERVICE_ROLE_KEY`. Never a value. |

Nothing here requires history rewriting, and nothing requires a key rotation on
history grounds.

---

## (c) `.gitignore` coverage

Tested with `git check-ignore -q` against a hypothetical path in each repo, not
by reading the patterns — so this reflects what git would actually do.

| Pattern | the-sporve-web | sporve-landing | SportsMan-main |
|---|---|---|---|
| `.env` | ignored | ignored | **NOT ignored** |
| `.env.local` | ignored | ignored | **NOT ignored** (except `sporve-react/` via `*.local`) |
| `.env.production` / `.env.*` | ignored | ignored | **NOT ignored** |
| `supabase/.temp/` | not ignored (no `supabase/` dir exists — N/A) | ignored | ignored |
| `.vercel/` | ignored | ignored | **NOT ignored** (no `.vercel/` dir exists today) |

**One real gap, MEDIUM, preventive:** `SportsMan-main/.gitignore` ignores only
the two specific paths `env.json` (line 38) and `supabase/functions/.env`
(line 42). A root-level `.env`, a `.env.local`, a `.env.production`, or any
`.env` in a *new* function directory would be staged by `git add -A` without
warning. Nothing has been committed — this is a trap that has not sprung yet.

Second, smaller gap: `the-sporve-web/.gitignore` has no `supabase/.temp/` line.
Harmless today because that repo has no `supabase/` directory, and worth adding
only if the CLI is ever linked from there.

---

## (d) Remediation — run these by hand, in this order

Nothing here is urgent. Item 1 is the only one that changes the security
posture; items 2–3 are hygiene.

**1. Close the `.env` gap in SportsMan-main (MEDIUM, do this).**

```bash
cd /Users/vishnusrikanth/SportsMan-main
printf '\n# Any local env file — secrets never enter git.\n.env\n.env.*\n!.env.example\n!*.env.example\n.vercel/\n' >> .gitignore
git diff -- .gitignore                 # read it before committing
git add .gitignore
git commit -m "chore(sec): ignore all .env variants and .vercel/"
```

Then confirm the rule actually bites — this must print `IGNORED` three times:

```bash
cd /Users/vishnusrikanth/SportsMan-main
for f in .env .env.local .env.production; do
  git check-ignore -q "$f" && echo "IGNORED $f" || echo "STILL EXPOSED $f"
done
git check-ignore -q supabase/functions/.env.example && echo "BAD: example is ignored" || echo "OK: example still tracked"
```

**2. Delete the two dead Vercel OIDC tokens (LOW, cosmetic).**

Both are expired and neither was ever committed, so this removes a stale file,
not a live risk. The Vercel CLI regenerates it on the next `vercel env pull`.

```bash
rm /Users/vishnusrikanth/the-sporve-web/.env.local
rm /Users/vishnusrikanth/Downloads/sporve-landing/.env.local
```

**3. Optional belt-and-braces for the-sporve-web (LOW).**

```bash
cd /Users/vishnusrikanth/the-sporve-web
printf '\n# Supabase CLI local state, if this repo is ever linked\nsupabase/.temp/\n' >> .gitignore
git add .gitignore && git commit -m "chore(sec): pre-emptively ignore supabase/.temp/"
```

**Not required, and explicitly not recommended:** any key rotation, any
`git filter-branch` / `git filter-repo`, any force-push. There is no committed
secret in any of the three repositories to expunge, and history rewriting on a
repo with a second remote (`cofounder`) would break that collaborator's clone
for no security gain.

---

## Five-sentence technical reading

**What changed:** nothing in any repository — this was a read-only sweep that
produced exactly one artifact, this file. **The mechanism:** two different
searches were run, a filesystem scan with `rg --hidden --no-ignore` (which
deliberately defeats `.gitignore`, because the whole point is to see the files
git is hiding) and a history scan with git's *pickaxe* — `-S` counts how many
times a literal string appears in a blob and shows you the commit where that
count changed, while `-G` does the same with a regular expression, so between
them they find a secret even if a later commit deleted it. **What it touches
downstream:** the `.gitignore` gap in `SportsMan-main` is the only live
exposure path, because git's ignore rules are *path-pattern* rules evaluated at
`git add` time, not content rules — an unignored `.env` is one `git add -A`
away from being permanent, since a blob that enters history stays reachable
through the reflog and any fork even after the file is deleted. **What would
break this conclusion:** a secret stored in a form the patterns do not match —
a base64-wrapped key, a key split across concatenated strings, a credential in
`.git/config`, `~/.claude`, or a Vercel/Supabase dashboard (all outside this
scope), or a *new* commit made after 2026-08-11. **How it was verified:** every
pickaxe hit was re-examined at the specific commit with a stricter
"prefix-plus-real-key-characters" regex and resolved to a placeholder, a
scanner's own pattern, prose, or a Skia symbol; both JWTs found on disk were
base64-decoded and read as Vercel OIDC tokens with no `role` claim and an `exp`
already in the past; and the `.gitignore` conclusions come from
`git check-ignore -q` on hypothetical paths rather than from reading patterns
by eye.
