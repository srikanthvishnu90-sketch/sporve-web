# Codex collaboration rules

Claude Code may edit this repository concurrently. Use Clo's local coordination
ledger to avoid stale reads and overwritten work.

Before changing files:

1. Read `.clo-sync/activity.md` when it exists and run `git status --short`.
2. Register intent: `python3 .claude/hooks/clo-sync.py begin codex "TASK" FILE...`.
3. If Claude has an unfinished claim on the same file, re-read the file and
   narrow the edit or leave a ledger `note`; never overwrite it from stale context.

After changing files, run the relevant verification and register completion:

`python3 .claude/hooks/clo-sync.py end codex "RESULT; verification: CHECK" FILE...`

Log only observable work—task, files, checks, conflicts, and handoffs. Never log
prompts, secrets, tool responses, private reasoning, or chain of thought. The
ledger is runtime state and is intentionally ignored by Git. Source files remain
the authority; `.clo-sync/activity.md` is coordination evidence only.

## Release every completed change

Work with Clo as the release gate. A repository change is not complete from a
local diff or passing test alone. After verification:

1. Re-read `git status` and the diff; commit only the intended files.
2. Push the current `main` commit to `origin/main` on GitHub.
3. Wait for that commit's Vercel production deployment for project
   `the-sporve-web` to finish successfully.
4. Verify `https://the-sporve-web.vercel.app` using a source marker, response
   size comparison, or live DOM assertion. Do not search served HTML for text
   produced at runtime by a template literal.
5. Record the commit SHA, deployment result, verification method, and live URL
   in the Clo ledger and final report.

If push, deployment, or live verification fails, report the task as blocked or
incomplete—never as done. Never force-push, bypass a failed smoke test, include
another agent's unfinished files, or deploy a critical-path change without its
required review.
