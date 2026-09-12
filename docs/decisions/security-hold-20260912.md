# Security release hold —2026-09-12

Status: OPEN. No launch acceptance or cleanup completion is claimed.
Observed at2026-09-12 21:12UTC through read-only GitHub APIs.
No suspicious payload was executed or deobfuscated by this investigation.

## Confirmed evidence

- Source main88ac75f40390bc978109f87c751fc3122662c9c0 contains
  .vscode/tasks.json blob5e226620d2e360205cc8634e3c581a008d382561.
  Its task labeled eslint-check runs Node against
  public/fonts/fa-solid-400.woff2, with runOn=folderOpen and hidden output.
- .vscode/settings.json blob934d55548c36ff0e330f2a2ba69bf74b10a7dcba
  sets task.allowAutomaticTasks=true.
- The supposed font is32,218 bytes of obfuscated JavaScript, not a WOFF2 font.
  Blob1390124885046fd4b6f6dd3a61410a8ae3cf9856 starts with global.i assignment,
  contains network/RPC, eval and child-process/spawn code, and ends in run().
  Its full executable contents are deliberately not copied into this report.
- Identical task/settings/payload blobs appear on current PR399, PR415 and
  PR412 branches. Unexpected accompanying changes include .gitignore,
  editor settings and a bundle of font files.
- No author or root cause is established. Git author metadata does not prove
  who performed the ref updates. No credential exfiltration or device execution
  has been established.

## Tested commits are not the current branch heads

| Branch | Previously recorded commit | Observed changed head |
| --- | --- | --- |
| codex/prompt1-sql-verification | ab54a7b2ebc02ada46439ce3a63b33b3a96bcfe6 |24cb7fe9771d6ec20ae524d68150ab7b128ea5bf |
| codex/entitlement-source-contract-20260910 |96009cf429fc5a1ea10b286b6f2a1aa9f8c17936 |917e48a99e72bdd06ae0e72274a8dae0cf9264ed |
| codex/launch-driver-20260910 |b5c9d2a5750c95c71be24ebe12dd6da0e215c060 |15373ae25ad0fea4e4e1e3417d9cb736ab15217b |

The first two comparisons report diverged, not an ordinary forward addition.
Original run34542507155 still identifies headab54a7b2 and concludes success;
run34538507840 still identifies96009cf4 and concludes success. Those historical
checks do NOT approve the replacement heads or their unexpected additions.

## Actions actually taken

- Stopped further builds, deployments, merges and launch feature changes.
- Warned the owner not to open this repository in an editor with automatic tasks.
- Posted superseding SECURITY RELEASE HOLD comments:
  PR399 comment5648716406, PR415 comment5648716573,
  PR412 comment5648717770.
- Re-read the earlier checkpointb5c9d2a5750c95c71be24ebe12dd6da0e215c060:
  its commit changes only STATE.md; recursive tree read was not truncated
  and contains neither the suspicious task nor the disguised font.
- Created this documentation-only hold branch from that checkpoint.
  No current main/working branch was reset, force-pushed or overwritten.
  This branch is NOT a release candidate and has not been deployed.
- The mirror repository's .vscode/tasks.json lookup returned404. That does not
  prove the whole mirror, a deployment, or a local checkout is clean.
- No suspicious files were deleted; original Git evidence remains available.

## Required containment and resume conditions

1. Keep affected trees out of editors that can run automatic tasks, and do not
   run the disguised font, repository scripts or fresh installs during triage.
2. A repository administrator must investigate GitHub account/app/session and
   ref-update activity from a trusted device; identify and disable any
   unauthorized writer before restoring release access.
3. If an affected tree was opened with automatic tasks enabled, treat that
   workstation and credentials accessible to it as potentially exposed until
   examined. Rotate/revoke affected credentials from a trusted device after
   identifying scope; no blanket claim that every credential was stolen.
4. Preserve the Git objects and relevant audit evidence. Prepare a reviewed,
   non-destructive cleanup of the unexpected additions against a verified
   checkpoint; do not blindly reset main or overwrite concurrent legitimate work.
5. Re-establish trusted branch ancestry and reproduce CI on the exact reviewed
   successor. Only then resume Prompt1 and the normal Clo/mirror/Vercel release.

These steps require repository/account administration and possible device
incident response, which the current repository-content connection cannot
perform or verify. No automatic cleanup commit can establish that the writer
or a potentially affected workstation has been contained.

## Launch work preserved, not accepted

Historical supporting evidence includes the real catalog/trial resolver plus
capacity guards through signed HTTP: expired trial402 without cron, active
trial201, cross-org resolver403, two observed concurrent requests for a final
slot, and an observed assignment downgrade blocking the waiting insert.
Run34542507155/job103088015637 recorded those checks; all11 SQL jobs in
run34542507189 and pr-checks34542507182 passed on the earlier recorded source.
P1.02 corrections passed source scan,11 frontend tests,7 checkout tests and36
browser assertions at390px/1440px, with build stamp3ea04337b8d34db3.
They remain supporting tests, not approved/current production evidence.

All six launch prompts remain unfinished. COMPLETE.md must not be created.
